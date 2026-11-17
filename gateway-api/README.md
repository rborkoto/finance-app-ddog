# gateway-api

Python 3.11 / FastAPI service. Port `8080`.

The public REST API. Validates Keycloak-issued JWTs on every request and routes to `account-service` and `transaction-service`. Uses Redis for sessions.

| Method | Path |
|---|---|
| GET | `/health` |
| GET | `/v1/payments` |
| POST | `/v1/payments` |
| POST | `/v1/transfers` |
| POST | `/v1/accounts/{account_id}/deposit` |
| GET | `/v1/accounts/{account_id}/balance` |

Example payment request body:

```json
{ "amount": 250.00, "currency": "EUR", "account_id": "acc-0042" }
```

Manifest: `deploy/kubernetes/base/services/gateway-api.yaml`.
