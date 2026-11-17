package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-stomp/stomp/v3"
)

const (
	alertQueue       = "/queue/alert.queue"
	defaultBrokerURL = "stomp://localhost:61613"
)

// AlertMessage represents the payload received on alert.queue.
type AlertMessage struct {
	EventType     string `json:"event_type"` // e.g. "fraud_detected", "payment_failed"
	AccountID     string `json:"account_id"`
	Channel       string `json:"channel"`        // "email" or "sms"
	CorrelationID string `json:"correlation_id"` // jms.correlation_id — business-level trace key
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	brokerURL := getEnv("ACTIVEMQ_URL", defaultBrokerURL)

	slog.Info("notification-service starting",
		"broker_url", brokerURL,
		"queue", alertQueue,
	)

	// Graceful shutdown on SIGTERM / SIGINT (important for K8s pod lifecycle).
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	// Outer reconnect loop. ActiveMQ Artemis closes idle STOMP connections
	// (AMQ229014 connection TTL). Rather than exiting on disconnect and relying
	// on a Kubernetes restart, reconnect in-process with a short backoff.
	for ctx.Err() == nil {
		conn, err := connectSTOMP(brokerURL)
		if err != nil {
			slog.Error("failed to connect to STOMP broker; retrying", "error", err, "broker_url", brokerURL)
			if sleepCtx(ctx, 3*time.Second) {
				return
			}
			continue
		}
		slog.Info("connected to STOMP broker", "broker_url", brokerURL)

		sub, err := conn.Subscribe(alertQueue, stomp.AckClient)
		if err != nil {
			slog.Error("failed to subscribe to queue; reconnecting", "queue", alertQueue, "error", err)
			_ = conn.Disconnect()
			if sleepCtx(ctx, 3*time.Second) {
				return
			}
			continue
		}
		slog.Info("subscribed to queue", "queue", alertQueue)

		// Consume until the subscription channel closes (broker disconnect) or shutdown.
		consume(ctx, conn, sub)
		_ = conn.Disconnect()

		if ctx.Err() != nil {
			return // clean shutdown
		}
		slog.Warn("STOMP connection lost; reconnecting", "queue", alertQueue)
		if sleepCtx(ctx, 3*time.Second) {
			return
		}
	}
}

// consume reads messages until the subscription channel closes or ctx is cancelled.
func consume(ctx context.Context, conn *stomp.Conn, sub *stomp.Subscription) {
	for {
		select {
		case <-ctx.Done():
			slog.Info("shutdown signal received, stopping consumer")
			return
		case msg, ok := <-sub.C:
			if !ok {
				return
			}
			processMessage(conn, msg)
		}
	}
}

// sleepCtx waits for d or until ctx is cancelled; returns true if cancelled.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	select {
	case <-ctx.Done():
		return true
	case <-time.After(d):
		return false
	}
}

// processMessage deserialises the STOMP frame and dispatches to sendNotification.
func processMessage(conn *stomp.Conn, msg *stomp.Message) {
	if msg.Err != nil {
		slog.Error("received error frame from broker", "error", msg.Err)
		return
	}

	var alert AlertMessage
	if err := json.Unmarshal(msg.Body, &alert); err != nil {
		slog.Error("failed to unmarshal alert message",
			"error", err,
			"raw_body_length", len(msg.Body),
		)
		// NACK the message so the broker can redeliver or dead-letter it.
		if nackErr := conn.Nack(msg); nackErr != nil {
			slog.Error("failed to NACK message", "error", nackErr)
		}
		return
	}

	slog.Info("jms.message.process",
		"queue", alertQueue,
		"event_type", alert.EventType,
		"account_id", alert.AccountID,
		"channel", alert.Channel,
		"correlation_id", alert.CorrelationID,
	)

	sendNotification(alert)

	if err := conn.Ack(msg); err != nil {
		slog.Error("failed to ACK message", "error", err, "correlation_id", alert.CorrelationID)
	}
}

// sendNotification stubs the email / SMS dispatch logic.
// In production this would call an SMTP relay or SMS gateway API.
func sendNotification(alert AlertMessage) {

	start := time.Now()

	switch alert.Channel {
	case "email":
		fields := []any{
			"channel", "email",
			"event_type", alert.EventType,
			"account_id", alert.AccountID,
			"correlation_id", alert.CorrelationID,
		}
		slog.Info("alert.send", fields...)
		// TODO: integrate with SMTP relay (e.g. SendGrid, SES)
	case "sms":
		fields := []any{
			"channel", "sms",
			"event_type", alert.EventType,
			"account_id", alert.AccountID,
			"correlation_id", alert.CorrelationID,
		}
		slog.Info("alert.send", fields...)
		// TODO: integrate with SMS gateway (e.g. Twilio, SNS)
	default:
		slog.Warn("alert.send.unknown_channel",
			"channel", alert.Channel,
			"event_type", alert.EventType,
			"correlation_id", alert.CorrelationID,
		)
	}

	duration := time.Since(start).Milliseconds()

	completeFields := []any{
		"channel", alert.Channel,
		"event_type", alert.EventType,
		"duration_ms", duration,
		"correlation_id", alert.CorrelationID,
	}
	slog.Info("alert.send.complete", completeFields...)

}

// connectSTOMP establishes a STOMP connection to the ActiveMQ Artemis broker.
// Retries with a fixed delay to handle broker startup ordering in Docker Compose.
func connectSTOMP(rawURL string) (*stomp.Conn, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}

	host := u.Host
	var password string
	if u.User != nil {
		password, _ = u.User.Password()
	}
	user := u.User.Username()

	opts := []func(*stomp.Conn) error{
		stomp.ConnOpt.HeartBeat(10*time.Second, 10*time.Second),
	}
	if user != "" {
		opts = append(opts, stomp.ConnOpt.Login(user, password))
	}

	const maxRetries = 10
	for i := range maxRetries {
		conn, dialErr := stomp.Dial("tcp", host, opts...)
		if dialErr == nil {
			return conn, nil
		}
		slog.Warn("STOMP connection failed, retrying",
			"attempt", i+1,
			"max_attempts", maxRetries,
			"error", dialErr,
		)
		time.Sleep(3 * time.Second)
	}

	// Final attempt — return the error directly.
	return stomp.Dial("tcp", host, opts...)
}

// getEnv returns the value of an environment variable or a fallback default.
func getEnv(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}
