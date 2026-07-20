# fraud-detection

Async fraud-scoring microservice for the Finance sample application.

Listens on `fraud.score.queue` via ActiveMQ Artemis (STOMP protocol), scores each inbound
transaction, and logs a structured JSON result. Written in Python 3.11.

---

## Quick Start

```bash
cp .env.example .env
# Fill in STOMP_HOST, STOMP_USER, STOMP_PASS if different from defaults.
docker build -t fraud-detection:dev .
docker run --env-file .env fraud-detection:dev
```

The service connects to `activemq-artemis:61613` and waits for messages on `fraud.score.queue`.

---

## Sending a Test Message

Use the ActiveMQ Artemis web console (`http://localhost:8161`) or the STOMP CLI:

> **Credentials note:** `admin` / `admin` below only works against a standalone local broker running with
> default auth (e.g. `docker run activemq/artemis`). The actual deployed cluster uses the `artemis-password`
> secret from the `app-secrets` K8s Secret (`deploy/kubernetes/base/02-secrets.yaml`), which defaults to
> `artemis_dev_password`. To test against the deployed cluster, run
> `kubectl port-forward svc/activemq-artemis 8161:8161 -n finance` first and swap in that password
> (or read it via `kubectl get secret app-secrets -n finance -o jsonpath='{.data.artemis-password}' | base64 -d`).

```bash
# Install stomp CLI
pip install stomp.py

python - <<'EOF'
import stomp, json, time

conn = stomp.Connection([("localhost", 61613)])
conn.connect("admin", "admin", wait=True)  # local standalone broker only — see note above for the deployed cluster
conn.send(
    destination="/queue/fraud.score.queue",
    body=json.dumps({
        "transaction_id": "txn-test-001",
        "amount": 6500.00,
        "currency": "EUR",
        "transaction_type": "payment",
        "account_id": "acc-42"
    }),
    headers={"content-type": "application/json"},
)
time.sleep(0.5)
conn.disconnect()
print("Message sent.")
EOF
```

Expected log output (structured JSON):

```json
{
  "asctime": "2026-06-03T09:00:01",
  "levelname": "INFO",
  "name": "fraud_detection.listener",
  "message": "Fraud score computed",
  "transaction_id": "txn-test-001",
  "transaction.type": "payment",
  "payment.currency": "EUR",
  "fraud.score": 0.9,
  "fraud.score_bucket": "high",
  "messaging.destination": "fraud.score.queue",
  "jms.correlation_id": ""
}
```

---

## Project Structure

```
fraud-detection/
├── main.py          # Entry point: STOMP connection + listen loop
├── listener.py      # on_message handler, scoring orchestration, logging
├── scorer.py        # Deterministic fraud scoring stub
├── requirements.txt # Runtime dependencies
├── Dockerfile       # python:3.11-slim image
├── .env.example     # Broker / queue configuration
└── README.md        # This file
```

---

## Scoring Buckets

| Bucket | Amount range | Score |
|--------|--------------|-------|
| `low` | `< 1,000` | 0.10 |
| `medium` | `1,000` – `< 5,000` | 0.55 |
| `high` | `>= 5,000` | 0.90 |
