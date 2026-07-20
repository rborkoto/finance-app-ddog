# batch-processor — Finance Sample App

Spring Boot 3 / Spring Batch 5 / Java 17 service that runs two scheduled batch jobs:

| Job | Schedule | Purpose |
|---|---|---|
| `end-of-day-reconciliation` | Nightly 23:00 UTC | Reads settled transactions, compares against external ledger, writes discrepancy report |
| `monthly-statement-generation` | 1st of month, 01:00 UTC | Reads account history, generates PDF statement stubs per account |

---

## Running locally

```bash
# Copy and fill in environment variables
cp .env.example .env

# Build
./gradlew build

# Run (requires a PostgreSQL instance — see kubectl get pods -n finance # postgres-ledger runs in the finance namespace)
java -jar build/libs/batch-processor-*.jar

# Trigger a job manually (spring.batch.job.enabled=false disables auto-launch on startup —
# see BatchJobController.java for the real endpoints; there is no /actuator/batch/jobs/... path)
curl -X POST http://localhost:8083/jobs/reconciliation
curl -X POST http://localhost:8083/jobs/statement
```

---

## HTTP endpoints

The service exposes an embedded web server (port 8083) for:

- On-demand job triggers: `POST /jobs/reconciliation`, `POST /jobs/statement` (see `BatchJobController`).
- Spring Boot Actuator health/metrics endpoints: `/actuator/health`, `/actuator/metrics`, `/actuator/prometheus`.
