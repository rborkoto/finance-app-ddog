# batch-processor

Java 17 / Spring Boot 3 / Spring Batch 5 service. Port `8083`.

Runs two batch jobs against PostgreSQL (`postgres-ledger`). They do not run on a schedule in this sample app. Trigger them over HTTP.

| Job | Trigger | Purpose |
|---|---|---|
| `end-of-day-reconciliation` | `POST /jobs/reconciliation` | Reads the day's settled transactions and reconciles them |
| `monthly-statement-generation` | `POST /jobs/statement` | Generates statement stubs per account |

```bash
kubectl port-forward deploy/batch-processor 8083:8083 -n finance
# in a second terminal:
curl -s -X POST localhost:8083/jobs/reconciliation
```

Each run logs a one-line summary at the end (status, records read, written and skipped).

Manifest: `deploy/kubernetes/base/services/batch-processor.yaml`.
