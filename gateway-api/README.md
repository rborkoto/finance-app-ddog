# gateway-api

Public-facing REST gateway for the Finance sample application.
Built with Python 3.11 and FastAPI.

## Responsibilities

- Authentication middleware (stub)
- Route `/v1/payments` → transaction-service
- Route `/v1/accounts/{id}/balance` → account-service
- Structured JSON logging (python-json-logger)
- Health probe at `GET /health`

## Quick Start

```bash
cp .env.example .env
# Edit .env — set ACCOUNT_SERVICE_URL and TRANSACTION_SERVICE_URL
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8080 --reload
```

## API Reference

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Liveness probe |
| POST | `/v1/payments` | Initiate a payment |
| GET | `/v1/accounts/{account_id}/balance` | Retrieve account balance |

### POST /v1/payments

Request body:

```json
{
  "amount": 250.00,
  "currency": "EUR",
  "account_id": "acc-0042"
}
```

Response (201):

```json
{
  "payment_id": "pay-3f8a1c2b9d0e",
  "status": "pending",
  "amount": 250.00,
  "currency": "EUR",
  "account_id": "acc-0042"
}
```
