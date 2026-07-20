package com.example.finance.account.messaging;

import com.example.finance.account.model.Account;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jms.core.JmsTemplate;
import org.springframework.stereotype.Component;

import jakarta.jms.Session;
import java.util.Map;

/**
 * Publishes account lifecycle events to ActiveMQ Artemis queues.
 *
 * Queues:
 *   fraud.score.queue — consumed by fraud-detection service (Python)
 *   alert.queue       — consumed by notification-service (Go)
 */
@Component
public class PaymentEventProducer {

    private static final Logger log = LoggerFactory.getLogger(PaymentEventProducer.class);

    static final String FRAUD_SCORE_QUEUE = "fraud.score.queue";
    static final String ALERT_QUEUE = "alert.queue";

    private final JmsTemplate jmsTemplate;
    private final ObjectMapper objectMapper = new ObjectMapper();

    public PaymentEventProducer(JmsTemplate jmsTemplate) {
        this.jmsTemplate = jmsTemplate;
    }

    /**
     * Sends an account-created event to fraud.score.queue.
     * The fraud-detection service consumes this asynchronously and assigns a risk score.
     */
    public void sendAccountCreatedEvent(Account account) {
        var payload = Map.of(
                "eventType", "account.created",
                "accountId", account.getId(),
                "tier", account.getTier(),
                "currency", account.getCurrency()
                // NOTE: balance and ownerId intentionally omitted — PII / sensitive financial data.
                // Resolve these in the consumer service using the accountId reference.
        );

        log.info("event=jms.produce queue={} event_type=account.created account_tier={} currency={}",
                FRAUD_SCORE_QUEUE, account.getTier(), account.getCurrency());

        try {
            jmsTemplate.send(FRAUD_SCORE_QUEUE, session -> {
                var message = session.createTextMessage(toJson(payload));
                return message;
            });

            log.info("event=jms.produce status=sent queue={}", FRAUD_SCORE_QUEUE);

        } catch (Exception e) {
            log.error("event=jms.produce status=error queue={} error_type={} message={}",
                    FRAUD_SCORE_QUEUE, e.getClass().getSimpleName(), e.getMessage());
        }
    }

    /**
     * Sends a payment-initiated alert to alert.queue.
     * The notification-service (Go) consumes this to dispatch email/SMS stubs.
     *
     * BUG FIX — schema mismatch: this used to send camelCase keys
     * ("eventType", "accountId") with no "channel" or "correlation_id"
     * field at all. notification-service's AlertMessage struct expects
     * snake_case JSON keys ("event_type", "account_id", "channel",
     * "correlation_id" — see notification-service/main.go). Go's
     * encoding/json silently leaves unmatched struct fields at their zero
     * value instead of erroring, so every alert was "processed" with
     * completely empty event_type/account_id/channel/correlation_id and
     * logged a WARN "alert.send.unknown_channel" — no error, no crash,
     * just silently wrong data. This was invisible until the STOMP
     * anycastPrefix/multicastPrefix routing fix (see broker.xml) let any
     * message reach the consumer at all.
     */
    public void sendPaymentAlert(String accountId, String currency, String tier) {
        // Premium/corporate accounts get an SMS alert (higher urgency SLA);
        // retail accounts get email. Bounded set of values — safe as a tag.
        String channel = ("premium".equals(tier) || "corporate".equals(tier)) ? "sms" : "email";
        // Business-level correlation key across the async hop, independent of
        // the broker-assigned message ID. Short and prefixed, not a raw UUID,
        // to keep it readable in logs while still being effectively unique.
        String correlationId = "alert-" + java.util.UUID.randomUUID().toString().substring(0, 8);

        var payload = Map.of(
                "event_type", "payment.initiated",
                "account_id", accountId,
                "channel", channel,
                "correlation_id", correlationId,
                "currency", currency,
                "tier", tier
        );

        log.info("event=jms.produce queue={} event_type=payment.initiated account_tier={} currency={} channel={} correlation_id={}",
                ALERT_QUEUE, tier, currency, channel, correlationId);

        try {
            jmsTemplate.send(ALERT_QUEUE, session -> {
                var message = session.createTextMessage(toJson(payload));
                return message;
            });

            log.info("event=jms.produce status=sent queue={}", ALERT_QUEUE);

        } catch (Exception e) {
            log.error("event=jms.produce status=error queue={} error_type={} message={}",
                    ALERT_QUEUE, e.getClass().getSimpleName(), e.getMessage());
        }
    }

    /**
     * JSON serialisation via Jackson's ObjectMapper (already on the classpath
     * via spring-boot-starter-web).
     *
     * BUG FIX: this used to be a hand-rolled string concatenation
     * (`"{\"" + k + "\":\"" + v + ...}"`) with no escaping at all. Any field
     * value containing a quote, backslash, or control character produced
     * broken JSON on the wire — consumers (fraud-detection, notification-
     * service) would fail with e.g. "Invalid control character at: line 1
     * column 41" and silently drop the message after logging a parse error.
     * Jackson handles escaping correctly and is already a dependency, so
     * there is no reason to hand-roll this.
     */
    private String toJson(Map<String, String> map) {
        try {
            return objectMapper.writeValueAsString(map);
        } catch (Exception e) {
            log.error("event=jms.produce status=serialization_error error_type={} message={}",
                    e.getClass().getSimpleName(), e.getMessage());
            return "{}";
        }
    }
}
