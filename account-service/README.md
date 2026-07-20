# account-service

Java 17 / Spring Boot 3.x microservice for the Finance sample application.

Responsibilities: account CRUD, balance enquiry, JMS event production to `fraud.score.queue` and `alert.queue`.

---

## Finance Domain Attributes Reference

| Attribute | Type | Example | Purpose |
|-----------|------|---------|---------|
| `account.tier` | string | `premium` | SLA-aware handling — premium accounts get higher priority |
| `payment.currency` | string | `EUR` | Regulatory and regional analysis |
| `transaction.type` | string | `payment` | Categorise transactions |
| `messaging.destination` | string | `fraud.score.queue` | JMS queue name |

---

## Local Development

```bash
# Run the service
./gradlew bootRun

# Build fat JAR
./gradlew bootJar

# Build Docker image
docker build -t account-service:local .
```

## Project Structure

```
account-service/
  src/main/java/com/example/finance/account/
    AccountServiceApplication.java     # Spring Boot entry point
    controller/AccountController.java  # REST endpoints
    service/AccountService.java        # Business logic
    model/Account.java                 # Domain model
    messaging/PaymentEventProducer.java # JMS producer
  src/main/resources/
    application.yml                    # Spring config (env-var driven)
    logback-spring.xml                 # Structured JSON logging
  build.gradle                         # Dependencies
  Dockerfile                           # eclipse-temurin:17-jre runtime
  .env.example                         # Environment variables
```

## Endpoints

- `GET  /health` — liveness/readiness check
- `GET  /v1/accounts` — list all accounts
- `GET  /v1/accounts/{id}` — get account by ID
- `GET  /v1/accounts/{id}/balance` — check account balance
- `POST /v1/accounts` — create a new account
- `PATCH /v1/accounts/{id}/balance` — apply a balance delta (debit/credit)
- `POST /v1/accounts/{id}/payment-alert` — publish a payment-initiated alert
