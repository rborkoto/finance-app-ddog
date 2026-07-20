# transaction-service

Node.js 20 / Express microservice for the Finance sample application.
Handles payment initiation, ledger writes (PostgreSQL stub), and
fraud-scoring event production to ActiveMQ Artemis via STOMP.

---

## Local Development

```bash
cp .env.example .env
# Edit .env — set ACTIVEMQ_URL and POSTGRES_URL for your local broker/DB
npm install
npm run dev        # nodemon — reloads on file changes
```

Send a test payment:

```bash
curl -X POST http://localhost:8082/v1/payments \
  -H 'Content-Type: application/json' \
  -d '{"amount":250.00,"currency":"EUR","account_id":"acc-042"}'
```

Retrieve it:

```bash
curl http://localhost:8082/v1/payments/<payment_id from response>
```

Health check:

```bash
curl http://localhost:8082/health
```

---

## Environment Variables

See `.env.example` for the full reference with inline explanations.

| Variable | Default | Description |
|---|---|---|
| `SERVICE_NAME` | `transaction-service` | Service name used in log records |
| `APP_ENV` | `development` | Environment name used in log records |
| `APP_VERSION` | `0.0.0` | Version / image tag used in log records |
| `PORT` | `8082` | HTTP listen port |
| `ACTIVEMQ_URL` | `stomp://localhost:61613` | Broker STOMP endpoint |
| `POSTGRES_URL` | — | PostgreSQL connection string |
| `LOG_LEVEL` | `info` | pino log level |
