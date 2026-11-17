# frontend-stub

Single-page browser dashboard for Meridian Financial, served by nginx at `http://localhost:30080`.

Login goes through Keycloak (see the root README for users and roles). Depending on role, the dashboard lists accounts, checks balances, initiates payments and transfers, makes deposits, and approves or rejects pending payments. All calls go to `gateway-api` under `/v1/`.

The HTML is served from the `frontend-dashboard` ConfigMap, not from an image. After editing `index.html`, refresh it:

```bash
kubectl create configmap frontend-dashboard --from-file=index.html=frontend-stub/index.html -n finance --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/frontend -n finance
```
