# frontend-stub

Minimal browser client simulating a Finance platform dashboard. It provides:

- A **payment form** (amount, currency, account ID, transaction type) that calls `POST /v1/payments`.
- An **account balance panel** that calls `GET /v1/accounts/{id}/balance`.
- Structured JSON console logging for local debugging.

The page runs with zero observability configuration.

---

## Running Locally

This is a static HTML file. Serve it from any HTTP server:

```bash
# Python
python3 -m http.server 3000 --directory frontend-stub/

# Node (npx)
npx serve frontend-stub/ -l 3000
```

The JS fetch calls expect the backend APIs to be reachable at the same origin, proxied via the **NGINX Kubernetes Service** (`deploy/kubernetes/base/services/frontend.yaml`), exposed on `http://localhost:30080` after `make deploy-k8s`. When serving this file standalone (outside the cluster), update the fetch URLs or configure a local reverse proxy to point at `http://localhost:30080`.
