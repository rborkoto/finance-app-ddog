package com.example.finance.account.service;

import com.example.finance.account.messaging.PaymentEventProducer;
import com.example.finance.account.model.Account;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.Collection;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

@Service
public class AccountService {

    private static final Logger log = LoggerFactory.getLogger(AccountService.class);

    private final Map<String, Account> store = new ConcurrentHashMap<>();

    private final PaymentEventProducer paymentEventProducer;

    public AccountService(PaymentEventProducer paymentEventProducer) {
        this.paymentEventProducer = paymentEventProducer;

        // Seed data for local development
        var seed = new Account(
                "acc-001",
                "owner-42",
                new BigDecimal("12500.00"),
                "EUR",
                "premium",
                Instant.now()
        );
        store.put(seed.getId(), seed);
    }

    public Optional<Account> findById(String id) {
        return Optional.ofNullable(store.get(id));
    }

    public Collection<Account> findAll() {
        return store.values();
    }

    /**
     * Publishes a payment-initiated alert for the given account, resolving the
     * account's tier so the alert carries Finance-domain context.
     * Called by the gateway right after a finance-trader or finance-admin
     * successfully initiates a payment. Best-effort: notification dispatch
     * must never block or fail the payment itself.
     *
     * @return true if the account was found and the alert was published.
     */
    public boolean sendPaymentAlert(String accountId, String currency) {
        return findById(accountId)
                .map(account -> {
                    paymentEventProducer.sendPaymentAlert(accountId, currency, account.getTier());
                    return true;
                })
                .orElseGet(() -> {
                    log.warn("event=payment_alert status=account_not_found account_id={}", accountId);
                    return false;
                });
    }

    /**
     * Atomically applies a balance delta to an account.
     * Negative delta = debit (payment approved).
     * Positive delta = credit (refund or reversal).
     *
     * Thread-safe via ConcurrentHashMap#compute.
     */
    public Optional<Account> applyDelta(String id, BigDecimal delta) {
        Account[] result = { null };
        store.compute(id, (key, account) -> {
            if (account == null) return null;
            account.setBalance(account.getBalance().add(delta));
            result[0] = account;
            return account;
        });
        log.info("event=account.balance_updated account_tier={} currency={} delta={}",
                result[0] != null ? result[0].getTier() : "unknown",
                result[0] != null ? result[0].getCurrency() : "unknown",
                delta);
        return Optional.ofNullable(result[0]);
    }

    public BigDecimal getBalance(Account account) {
        log.info("event=account.balance_check account_tier={} currency={}",
                account.getTier(), account.getCurrency());

        BigDecimal balance = account.getBalance();

        return balance;
    }

    public Account createAccount(Account request) {
        String id = "acc-" + UUID.randomUUID().toString().substring(0, 8);
        var account = new Account(
                id,
                request.getOwnerId(),
                request.getBalance() != null ? request.getBalance() : BigDecimal.ZERO,
                request.getCurrency() != null ? request.getCurrency() : "EUR",
                request.getTier() != null ? request.getTier() : "retail",
                Instant.now()
        );
        store.put(account.getId(), account);

        log.info("event=account.create status=persisted account_tier={} currency={}",
                account.getTier(), account.getCurrency());

        // Publish account-created event — fraud pipeline picks this up via JMS
        paymentEventProducer.sendAccountCreatedEvent(account);

        return account;
    }
}
