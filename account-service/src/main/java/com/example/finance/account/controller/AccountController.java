package com.example.finance.account.controller;

import com.example.finance.account.model.Account;
import com.example.finance.account.service.AccountService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.Map;

@RestController
public class AccountController {

    private static final Logger log = LoggerFactory.getLogger(AccountController.class);

    private final AccountService accountService;

    public AccountController(AccountService accountService) {
        this.accountService = accountService;
    }

    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        log.info("event=health_check status=ok");
        return ResponseEntity.ok(Map.of("status", "ok", "service", "account-service"));
    }

    /**
     * Apply a balance delta to an account (debit or credit).
     *
     * Called by the gateway after a payment is approved:
     *   PATCH /v1/accounts/{id}/balance   {"delta": -500.00}
     *
     * A negative delta debits the account (approved outbound payment).
     * A positive delta credits the account (refund or reversal).
     */
    @PatchMapping("/v1/accounts/{id}/balance")
    public ResponseEntity<Map<String, Object>> updateBalance(
            @PathVariable String id,
            @RequestBody Map<String, Object> body) {

        Object rawDelta = body.get("delta");
        if (rawDelta == null) {
            return ResponseEntity.badRequest().body(Map.of("error", "'delta' field is required"));
        }
        BigDecimal delta = new BigDecimal(rawDelta.toString());

        return accountService.applyDelta(id, delta)
                .map(account -> {
                    log.info("event=account.balance_patched account_id={} delta={}", id, delta);
                    return ResponseEntity.ok(Map.<String, Object>of(
                            "accountId",  account.getId(),
                            "balance",    accountService.getBalance(account),
                            "currency",   account.getCurrency(),
                            "tier",       account.getTier()
                    ));
                })
                .orElseGet(() -> {
                    log.warn("event=account.balance_patched status=not_found account_id={}", id);
                    return ResponseEntity.<Map<String, Object>>notFound().build();
                });
    }

    /**
     * Publishes a payment-initiated alert for the given account.
     *
     * Called by gateway-api immediately after a finance-trader or
     * finance-admin successfully initiates a payment (POST /v1/payments).
     * notification-service (Go) consumes alert.queue and dispatches the
     * email/SMS stub. Best-effort — the gateway does not fail the payment
     * if this call fails or the account cannot be found.
     */
    @PostMapping("/v1/accounts/{id}/payment-alert")
    public ResponseEntity<Map<String, Object>> paymentAlert(
            @PathVariable String id,
            @RequestBody Map<String, String> body) {

        String currency = body.getOrDefault("currency", "UNKNOWN");
        log.info("event=payment_alert.request account_id={} currency={}", id, currency);

        boolean published = accountService.sendPaymentAlert(id, currency);
        if (!published) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.accepted().body(Map.of("accountId", id, "status", "alert_published"));
    }

    /**
     * List all accounts.
     * Used by the frontend dashboard to populate the account table.
     */
    @GetMapping("/v1/accounts")
    public ResponseEntity<Collection<Account>> listAccounts() {
        log.info("event=account.list");
        return ResponseEntity.ok(accountService.findAll());
    }

    @GetMapping("/v1/accounts/{id}")
    public ResponseEntity<Account> getAccount(@PathVariable String id) {
        log.info("event=account.get account_id={}", id);

        return accountService.findById(id)
                .map(account -> {
                    log.info("event=account.get status=found account_tier={} currency={}",
                            account.getTier(), account.getCurrency());
                    return ResponseEntity.<Account>ok(account);
                })
                .orElseGet(() -> {
                    log.warn("event=account.get status=not_found account_id={}", id);
                    return ResponseEntity.<Account>notFound().build();
                });
    }

    @GetMapping("/v1/accounts/{id}/balance")
    public ResponseEntity<Map<String, Object>> getBalance(@PathVariable String id) {
        log.info("event=account.balance_check account_id={}", id);

        return accountService.findById(id)
                .map(account -> {
                    var balance = accountService.getBalance(account);
                    log.info("event=account.balance_check status=ok account_tier={} currency={}",
                            account.getTier(), account.getCurrency());

                    return ResponseEntity.<Map<String, Object>>ok(Map.of(
                            "accountId", account.getId(),
                            "balance", balance,
                            "currency", account.getCurrency(),
                            "tier", account.getTier()
                    ));
                })
                .orElseGet(() -> {
                    log.warn("event=account.balance_check status=not_found account_id={}", id);
                    return ResponseEntity.<Map<String, Object>>notFound().build();
                });
    }

    @PostMapping("/v1/accounts")
    public ResponseEntity<Account> createAccount(@RequestBody Account request) {
        log.info("event=account.create currency={} tier={}", request.getCurrency(), request.getTier());

        try {
            Account created = accountService.createAccount(request);
            log.info("event=account.create status=created account_tier={} currency={}",
                    created.getTier(), created.getCurrency());
            return ResponseEntity.status(HttpStatus.CREATED).body(created);
        } catch (Exception e) {
            log.error("event=account.create status=error error_type={} message={}",
                    e.getClass().getSimpleName(), e.getMessage());

            return ResponseEntity.internalServerError().build();
        }
    }
}
