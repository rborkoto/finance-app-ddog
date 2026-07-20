# Finance Sample App — Troubleshooting Guide

When something isn't working, resist the urge to chase the first error message
you see. This app has three layers between "I ran a command" and "the app is
serving authenticated traffic," and a failure in an early layer often produces
a confusing symptom in a later one (e.g. a Keycloak secret mismatch shows up as
"the payment endpoint 500s," not as an auth error).

Work through the layers **in order**. Confirm each one is healthy before
investigating the next — this avoids debugging a real problem in Layer 3 when
the actual root cause is a broken Layer 1.

```
Infrastructure → Application → Identity
```

| # | Layer | Question |
|---|---|---|
| 1 | Infrastructure | Is Kubernetes healthy? |
| 2 | Application | Is the application healthy? |
| 3 | Identity | Is authentication working? |

---

## 1 — Infrastructure: Is Kubernetes healthy?

```bash
kubectl get nodes                    # all Ready
kubectl get pods -n finance          # all Running (12 pods, incl. traffic-generator)
kubectl get events -n finance --sort-by='.lastTimestamp' | tail -20
```

**Common failures at this layer:**
- Pods stuck in `Pending` — usually insufficient CPU/memory on the local
  cluster (Docker Desktop/Colima resource limits) or, on EKS, a node group
  that hasn't scaled up yet.
- Pods `CrashLoopBackOff` — check `kubectl logs -n finance <pod> --previous`
  for a stack trace.
- `ImagePullBackOff` on local — you likely skipped the image-load step for
  your local Kubernetes tool (kind/k3d/minikube/Colima all require it; Docker
  Desktop/Rancher Desktop don't). See root README's Prerequisites.

**Do not proceed past this layer** until every pod in the `finance` namespace
is `Running`. Everything downstream assumes a healthy cluster.

---

## 2 — Application: Is the application healthy?

```bash
kubectl exec -n finance deploy/gateway-api -- curl -s localhost:8080/health
kubectl port-forward svc/gateway-api 8080:8080 -n finance &
curl -s http://localhost:8080/health
```

**Common failures at this layer:**
- `500` errors on `/health` — check the failing service's own logs
  (`kubectl logs -n finance deploy/<service>`) for a stack trace. This is
  almost always a real application bug — rule it out before assuming a
  downstream dependency is at fault.
- A service can't reach PostgreSQL/ActiveMQ/Redis — check the init containers
  (`wait-for-postgres`, `wait-for-activemq`) completed:
  `kubectl logs -n finance <pod> -c wait-for-postgres`.
- ActiveMQ STOMP messages silently never arrive at a consumer — this is a
  broker-side address-naming mismatch (`anycastPrefix`/`multicastPrefix`),
  not an application bug. See the comment header in
  `deploy/kubernetes/base/infrastructure/activemq-broker-config.yaml`.

---

## 3 — Identity: Is authentication working?

```bash
# From the finance namespace, log in as a real user and confirm you get a token:
kubectl run -it --rm curl-test --image=curlimages/curl -n finance --restart=Never -- \
  curl -s -X POST http://keycloak:8080/realms/finance/protocol/openid-connect/token \
    -d grant_type=password -d client_id=finance-gateway \
    -d client_secret=<real-secret-from-app-secrets> \
    -d username=carol.admin -d password='Finance@2025!'
```

**Common failures at this layer:**
- `invalid_client_credentials` (401) — the caller's `KEYCLOAK_CLIENT_SECRET`
  doesn't match the real secret. The in-cluster `traffic-generator` reads it
  correctly from the `app-secrets` K8s Secret automatically; if you're
  running `scripts/generate-traffic.py` or `scripts/test-e2e.py` manually from
  your laptop, make sure `KEYCLOAK_CLIENT_SECRET` is exported from the real
  secret (`kubectl get secret app-secrets -n finance -o jsonpath='{.data.keycloak-client-secret}' | base64 -d`),
  not left at the `REPLACE_WITH_SECRET` placeholder default.
- Browser login redirects to the wrong host / cookie errors — `KEYCLOAK_PUBLIC_URL`
  in the `app-config` ConfigMap doesn't match how you're actually reaching the
  app (localhost vs. the EKS NLB hostname). See root README's Identity
  Provider section.
- **A failure here is very often mistaken for a downstream application
  problem** — a payment request that 401s never reaches the ledger write you
  were expecting, but the "missing write" is a symptom, not the cause. Always
  confirm auth is working (Layer 3) before debugging why a downstream action
  didn't happen.

---

## Quick reference: which layer explains this symptom?

| Symptom | Most likely layer |
|---|---|
| Pod won't start | 1 — Infrastructure |
| `curl /health` fails or times out | 2 — Application |
| `401` / `invalid_client_credentials` on any request | 3 — Identity |

## See also

- [README.md](./README.md) — Quick Start and Traffic Generator sections, with a "✅ Verify before continuing" checklist for the deploy stage.
