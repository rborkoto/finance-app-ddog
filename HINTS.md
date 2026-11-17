# Hints and stretch goals

Try each task from the docs first. These hints point you in the right direction without giving you the answer. If you are still stuck after the hints and [TROUBLESHOOTING.md](./TROUBLESHOOTING.md), ask your Datadog contact for the reference implementation.

---

## Hints for the core tasks

### Task 1: Agent

- Install the Agent in its own namespace. Single Step Instrumentation does not instrument applications in the namespace where the Agent runs, so putting it in `finance` breaks Task 4.
- Local clusters such as Docker Desktop and kind often use kubelet certificates the Agent cannot verify. If the Agent logs certificate errors talking to the kubelet, look at the kubelet TLS settings in the `DatadogAgent` spec. That setting is for local clusters only. Leave verification on in production.
- Give the cluster a name in your `DatadogAgent`. Several views and features group by cluster name.
- Keep your `DatadogAgent` in a file you can re-apply. You will edit it in almost every task.

### Task 2: Unified Service Tagging

- There are two layers: labels on the Deployment and its pod template, and environment variables in the container.
- You do not have to type each value twice. The Kubernetes downward API can fill an environment variable from a pod label.
- `make build` tags every image with the git short SHA as well as `latest` (`make version` prints it). That gives you a real `version` value. See stretch goal S9.

### Task 3: Logs

- The Autodiscovery log annotation is keyed by **container** name, which here matches the service name.
- Collecting every container's logs is quick but also collects Keycloak, NGINX, Redis and the traffic generator. Decide what Meridian would want to pay for.
- If a service's error logs show up with INFO status, look at which JSON field holds that service's level and whether Datadog recognises it. The Python services write `levelname`, the Node.js service writes a numeric pino `level`. A log pipeline remapper fixes it.
- Before Task 2 is done, `account-service` logs `DD_SERVICE_IS_UNDEFINED` as its service name. That is expected, and it goes away once `DD_SERVICE` is set.

### Task 4: APM

- Single Step Instrumentation relies on the Cluster Agent's admission controller. Check that it is enabled.
- Scope instrumentation to the `finance` namespace rather than the whole cluster.
- Injection happens when a pod is created. After changing the Agent config, restart the app's Deployments.
- To confirm injection on a pod, look at its init containers. You should see Datadog library init containers for that pod's language.

### Task 5: Log and trace correlation

Every service has to write the trace ID into its log lines, and each language does it differently:

- **Java** (`account-service`, `batch-processor`): the Java tracer puts trace IDs into the logging MDC. Both services' JSON encoders already write MDC fields, so check that the tracer's log injection setting is on.
- **Python** (`gateway-api`, `fraud-detection`): the services log through `python-json-logger`, which writes extra record attributes into the JSON. Enable the Python tracer's log injection.
- **Node.js** (`transaction-service`): the service logs with `pino`, which the Node.js tracer supports. Enable log injection.
- **Go** (`notification-service`): there is no automatic hook. This is part of stretch goal S1.

### Task 6: Database Monitoring

- The monitoring user needs the grants and the `explain_statement` function from the docs, or explain plans will not appear.
- In an Autodiscovery check config, use template variables such as `%%host%%` instead of hard-coding a pod IP.
- Keep the monitoring password out of the annotation. The Agent's secrets management can read a Kubernetes Secret.
- `postgres-ledger` already loads `pg_stat_statements`. Confirm it with `SHOW shared_preload_libraries;`.

### Task 7: RUM

- The dashboard handles balances and payment details, so mask user input in Session Replay.
- The page is served from the `frontend-dashboard` ConfigMap. Run `make deploy-k8s` to rebuild it, then restart `frontend`.
- RUM sessions only appear for real browser activity. The traffic generator does not create any.

### Task 8: Security

- App and API Protection runs inside the tracer, so it only works for the services Task 4 instrumented. It can be switched on per service with an environment variable or through Remote Configuration.
- Workload Protection needs kernel features (eBPF) that some local clusters do not provide. Check the security agent's status before assuming your config is wrong.
- Misconfigurations findings take a while to appear after you enable them.

### Task 9: Monitors, SLO, dashboard

- APM metrics such as `trace.<span name>.hits`, `.errors` and the latency distributions make a good basis for both the monitor and the SLO.
- Use template variables and tags in notification messages, so one monitor can serve every service and still route to the right team.
- Pick an SLO target you could defend to Meridian's CTO, and write down why.

---

## Stretch goals

### S1: Trace the Go service

**Goal:** `notification-service` appears in APM, with a span for each alert it sends.

Single Step Instrumentation does not support Go, so this needs a code change:
- Add the Go tracer, `github.com/DataDog/dd-trace-go/v2`, to `notification-service`.
- Start the tracer when the service starts, with service, env and version. Create a span around each message the consumer handles.
- The tracer has to reach the Agent. Either set `DD_AGENT_HOST` from the node IP (downward API, `status.hostIP`) or let the admission controller inject it.
- Rebuild the image, reload it, and run `make deploy-k8s`.

For log correlation, add the active span's trace and span IDs to the `slog` calls yourself.

**Docs:** [Tracing Go applications](https://docs.datadoghq.com/tracing/trace_collection/)

**Checkpoint:** `notification-service` appears on the service map downstream of the message broker, and its logs link to traces.

### S2: Custom spans and tags

**Goal:** traces show the business operations, not just HTTP and database calls.

Good candidates:
- payment authorisation in `gateway-api`
- the ledger commit and the recent-activity check in `transaction-service/src/services/ledger.js`
- scoring in `fraud-detection/scorer.py`

Things to watch:
- Tag with **bounded** values only. Use `fraud.score_bucket` (`low`, `medium`, `high`), not the raw score float. Use the currency, not the amount. Unbounded tag values explode cardinality and cost.
- Keep PII and financial data out of tags.
- With Single Step Instrumentation, the tracer is injected at runtime and is not a declared dependency (`dd-trace` is not in `package.json`, `ddtrace` is not in `requirements.txt`). If your code imports it directly, decide whether to add it as a dependency or guard the import. Otherwise the service crashes whenever it runs without the tracer.

**Docs:** [Custom instrumentation](https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/)

**Checkpoint:** a payment trace shows your custom spans with their tags, and you can filter traces by one of those tags.

### S3: Continuous Profiler

**Goal:** CPU and memory profiles for the instrumented services, linked to traces.

For services instrumented by Single Step Instrumentation, profiling is a configuration change.

**Docs:** [Continuous Profiler](https://docs.datadoghq.com/profiler/)

**Checkpoint:** profiles appear for at least the Java and Python services, and a slow trace links to its profile.

### S4: Data Streams Monitoring

**Goal:** see the payment pipeline from `transaction-service` through `fraud.score.queue` to `fraud-detection`, with throughput and lag per hop.

- The Java services use JMS, which the Java tracer handles once Data Streams is enabled.
- `transaction-service` (Node.js, `stompit`) and `fraud-detection` (Python, `stomp.py`) talk STOMP, which neither tracer instruments automatically. Set Data Streams checkpoints manually: a produce checkpoint where `transaction-service` publishes, and a consume checkpoint where `fraud-detection` receives. Look for `setProduceCheckpoint` in the Node.js tracer and `set_consume_checkpoint` in the Python tracer. The pathway context travels in the message headers.

**Docs:** [Data Streams Monitoring](https://docs.datadoghq.com/data_streams/)

**Checkpoint:** the Data Streams map shows `transaction-service`, `fraud.score.queue` and `fraud-detection` connected. This also makes Scenario 3 straightforward.

### S5: Batch job visibility

**Goal:** know when a batch job "succeeds" but processes far fewer records than usual.

- `batch-processor` logs a summary line after every run, with status and records read, written and skipped. A log-based metric on those counts, plus a monitor on it, catches silent failures.
- The Java tracer can also trace Spring Batch jobs and steps. Check the Java tracer's integration settings for your version.

**Checkpoint:** you can graph records written per reconciliation run, and a monitor alerts when it drops. This also makes Scenario 2 straightforward.

### S6: ActiveMQ Artemis integration

**Goal:** broker metrics such as queue depth, consumers and message rates for `fraud.score.queue` and `alert.queue`.

- The broker already exposes JMX on port `1099` (see `deploy/kubernetes/base/infrastructure/activemq.yaml`).
- JMX-based checks need a JMX-enabled Agent image, and the check is configured through Autodiscovery on the broker pod.

**Docs:** [ActiveMQ integration](https://docs.datadoghq.com/integrations/activemq/)

**Checkpoint:** queue size metrics for both queues appear and are on your dashboard.

### S7: Datadog configuration as code

**Goal:** your Task 9 monitors, SLO and dashboard as Terraform, applied with the Datadog provider. This needs the Application key.

- Recreate them in code rather than clicking. Exporting a dashboard's JSON from the UI is a fair starting point for the dashboard.
- Keep keys out of the Terraform files and out of git. Pass them as environment variables.

**Docs:** [Datadog Terraform provider](https://registry.terraform.io/providers/DataDog/datadog/latest/docs)

**Checkpoint:** `terraform destroy` followed by `terraform apply` brings back everything from Task 9.

### S8: Datadog SSO with Keycloak

**Goal:** log in to your sandbox org through the bundled Keycloak, using SAML.

The Keycloak realm already has a `datadog-saml` client. `identity-provider/README.md` walks through the Keycloak side, including the ACS URL for each Datadog site.

**Docs:** [SAML with Datadog](https://docs.datadoghq.com/account_management/saml/)

**Checkpoint:** you can log in to your sandbox org as a Meridian user.

### S9: Deployment Tracking

**Goal:** compare two versions of a service side by side.

Use the git short SHA from `make version` as the `version` tag instead of a fixed value. Then deploy a small change to one service and compare the two versions in APM.

**Docs:** [Deployment Tracking](https://docs.datadoghq.com/tracing/services/deployment_tracking/)

**Checkpoint:** the service page shows two versions with their error rates and latency.

### S10: Connect RUM and traces

**Goal:** from a RUM session, open the backend trace for a click, for example submitting a payment.

Configure the Browser SDK to propagate trace headers to the API the dashboard calls. Look for the tracing URL settings in the RUM docs.

**Checkpoint:** a payment action in a RUM session links to its `gateway-api` trace.

### S11: Synthetic tests

**Goal:** an API test on the payment flow and a browser test on login.

Datadog's public test locations cannot reach a local cluster. Use the [EKS path](./README.md#deploy-on-aws-eks-optional), or run a private location inside your cluster.

**Docs:** [Synthetic Monitoring](https://docs.datadoghq.com/synthetics/)

**Checkpoint:** both tests run on a schedule and appear on your dashboard.
