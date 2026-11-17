# Troubleshooting

When something doesn't work, resist chasing the first error you see. There are six layers between "I ran a command" and "I see data in Datadog", and a failure in an early layer often looks like a problem in a much later one. A Keycloak secret mismatch, for example, shows up as "no traces in APM", not as an auth error.

Work through the layers in order and confirm each one before you look at the next.

```
Infrastructure → Application → Identity → Agent → Instrumentation → Backend
```

| # | Layer | Question |
|---|---|---|
| 1 | Infrastructure | Is Kubernetes healthy? |
| 2 | Application | Is the app healthy? |
| 3 | Identity | Is authentication working? |
| 4 | Agent | Is the Datadog Agent running and connected to your org? |
| 5 | Instrumentation | Is each service sending telemetry to the Agent? |
| 6 | Backend | Is Datadog receiving and processing it? |

For the layer-6 symptom "nothing shows up anywhere", check the site first. It is the most common mistake in this exercise.

The commands below assume you installed the Agent in a `datadog` namespace and named your `DatadogAgent` `datadog`. Adjust them if you didn't.

---

## 1. Infrastructure: is Kubernetes healthy?

```bash
kubectl get nodes                          # all Ready
kubectl get pods -n finance                # 12 pods Running
kubectl get events -n finance --sort-by='.lastTimestamp' | tail -20
```

- **Pods stuck in `Pending`:** the cluster is out of CPU or memory. Raise the limits in Docker Desktop or Colima. On EKS, the node group may still be scaling.
- **`ImagePullBackOff` on a local cluster:** you skipped loading the images. kind, k3d, minikube and Colima need it, Docker Desktop and Rancher Desktop don't. See the README, "Loading images into your cluster".
- **`CrashLoopBackOff`:** run `kubectl logs -n finance <pod> --previous`.

Don't go further until every pod is `Running`.

## 2. Application: is the app healthy?

```bash
kubectl port-forward svc/gateway-api 8080:8080 -n finance
curl -s http://localhost:8080/health       # in a second terminal
kubectl logs -n finance deploy/<service>
```

- **A service can't reach PostgreSQL, ActiveMQ or Redis:** check that its wait init containers finished, for example `kubectl logs -n finance <pod> -c wait-for-postgres`.
- **A service started crashing after you changed it:** compare its manifest with `git diff`. A YAML indentation slip in `env` or `annotations` is the usual cause.
- **STOMP messages never reach a consumer:** that is a broker address naming issue, not an app bug. See the header of `deploy/kubernetes/base/infrastructure/activemq-broker-config.yaml`.

## 3. Identity: is authentication working?

```bash
kubectl logs -n finance deploy/traffic-generator --tail=50
```

- **The traffic generator shows 401 or `invalid_client_credentials`:** the client secret it uses doesn't match Keycloak's. Check the `app-secrets` Secret and the `traffic-generator` Deployment.
- **Dashboard login fails with `NetworkError` or "Failed to fetch":** you haven't accepted the self-signed certificate at `https://localhost:30443` in this browser yet.
- **Login redirects to the wrong host:** `KEYCLOAK_PUBLIC_URL` in the `app-config` ConfigMap doesn't match how you reach the app. This mostly happens on EKS. See [EKS.md](./EKS.md).

A request that fails auth never produces the trace you were looking for. Confirm this layer before you debug "why is my span missing".

## 4. Agent: is it running and connected?

```bash
kubectl get pods -n datadog
kubectl get datadogagent -n datadog
kubectl exec -n datadog ds/datadog-agent -c agent -- agent status
kubectl logs -n datadog ds/datadog-agent -c agent --tail=100
```

- **API key shown as invalid in `agent status`:** the Secret holds the wrong key, or the key belongs to a different org.
- **Valid key but nothing in your org:** the `site` in your `DatadogAgent` is wrong. It must match the URL you log in on. See the README, "Before you start".
- **Errors about kubelet certificates:** common on local clusters. See the Task 1 hints in [HINTS.md](./HINTS.md#task-1-agent).
- **Operator installed but no Agent pods:** check the Operator's logs, `kubectl logs -n datadog deploy/<operator deployment>`. It usually means the `DatadogAgent` spec has an error.
- **You changed the `DatadogAgent` but nothing happened:** confirm you re-applied it and that `kubectl get datadogagent -n datadog` reflects the change. The Operator then rolls the Agent pods.

## 5. Instrumentation: is each service sending to the Agent?

```bash
# Did Single Step Instrumentation inject this pod?
kubectl get pod -n finance -l app=gateway-api -o jsonpath='{.items[0].spec.initContainers[*].name}'; echo

# Which Datadog env vars did the pod end up with?
kubectl exec -n finance deploy/gateway-api -- env | grep '^DD_'

# Is the Agent receiving traces?
kubectl exec -n datadog ds/datadog-agent -c trace-agent -- agent status | grep -A5 "Receiver"
```

- **No Datadog init containers on the pod:**
  - The pod was created before you enabled instrumentation. Restart it with `kubectl rollout restart deployment -n finance`.
  - The pod is in the Agent's own namespace. Single Step Instrumentation skips that namespace.
  - Your namespace or pod targeting doesn't match `finance`.
  - The admission controller is disabled.
- **Some services traced, `notification-service` not:** expected. Go isn't supported by Single Step Instrumentation. See stretch goal S1.
- **Injected, but the Agent receives nothing:** the tracer can't reach the Agent. Check that APM is enabled on the Agent and that the pod knows the Agent's address.
- **Logs arrive but have no trace IDs:** see the Task 5 language notes in [HINTS.md](./HINTS.md#task-5-log-and-trace-correlation).
- **Tag or env var changes didn't take effect:** `kubectl rollout restart` doesn't re-read the manifest files. Run `make deploy-k8s` to re-apply them.
- **The RUM snippet change didn't take effect:** the page comes from the `frontend-dashboard` ConfigMap. Run `make deploy-k8s` to rebuild it, restart `frontend`, then hard-refresh the browser.
- **No Database Monitoring data:** run `agent status` and find the `postgres` check.
  - `authentication failed`: wrong user or password.
  - `permission denied`: missing grants.
  - No check listed at all: the Autodiscovery annotation isn't on the `postgres-ledger` pod, or it doesn't match the container name.
- **A service crashes with "Cannot find module 'dd-trace'" or `ModuleNotFoundError: ddtrace`:** your custom code imports the tracer directly, but the tracer is only injected at runtime. See stretch goal S2.

## 6. Backend: is Datadog receiving it?

```bash
# Use your site's API host, for example api.datadoghq.eu
curl -s "https://api.<your site>/api/v1/validate" -H "DD-API-KEY: <your API key>"
```

- **`{"valid":false}`:** wrong key, or the wrong site for this key.
- **Data in some products but not others:** look at the products individually.
  - Logs need log collection on the Agent.
  - RUM needs the Browser SDK's own `site` set.
  - Terraform needs the provider's API URL for your site.
  - Each one must use the same site.
- **Logs arrive but every line has INFO status:** see the Task 3 hints about the level field.
- **Expected traces are missing at high volume:** check ingestion controls and sampling under APM settings before assuming instrumentation is broken.

---

## Quick reference: which layer explains this symptom?

| Symptom | Start at |
|---|---|
| Pod won't start | 1 |
| `/health` fails or times out | 2 |
| 401 or `invalid_client_credentials` | 3 |
| Agent pods missing or crashing | 4 |
| Agent healthy, org completely empty | 4, then 6 (site) |
| Logs arrive, no traces at all | 5 |
| One service traced, another not | 5 (that pod's init containers) |
| Traces arrive, logs not linked | 5 (log injection) |
| Some products have data, others don't | 6 |
| Errors show as INFO | 6 (status remapping) |
