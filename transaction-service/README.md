# transaction-service

Node.js 20 / Express service. Port `8082`.

Initiates payments: checks recent account activity, writes the payment to the PostgreSQL ledger, and publishes a fraud-scoring event to `fraud.score.queue` on ActiveMQ Artemis over STOMP.

| Method | Path |
|---|---|
| GET | `/health` |
| POST | `/v1/payments` |
| GET | `/v1/payments` |
| GET | `/v1/payments/{id}` |

Code: `src/index.js` (app setup), `src/routes/payments.js`, `src/services/ledger.js` (PostgreSQL), `src/messaging/producer.js` (STOMP).

Manifest: `deploy/kubernetes/base/services/transaction-service.yaml`.
