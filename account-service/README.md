# account-service

Java 17 / Spring Boot 3 service. Port `8081`.

Owns customer accounts: account CRUD and balance enquiry, backed by PostgreSQL (`postgres-ledger`). Publishes payment events to ActiveMQ Artemis over JMS (`fraud.score.queue`, `alert.queue`).

| Method | Path |
|---|---|
| GET | `/health` |
| GET | `/v1/accounts` |
| POST | `/v1/accounts` |
| GET | `/v1/accounts/{id}` |
| GET | `/v1/accounts/{id}/balance` |
| PATCH | `/v1/accounts/{id}/balance` |
| POST | `/v1/accounts/{id}/payment-alert` |

Built by `make build`, deployed by `make deploy-k8s`. Manifest: `deploy/kubernetes/base/services/account-service.yaml`.
