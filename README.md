# Finance Sample App

A realistic financial platform built as a set of microservices spanning Python, Java, Node.js, and Go. It runs on Kubernetes (locally or on AWS EKS) and ships with an in-cluster traffic generator so the system is exercised continuously out of the box.

> Something not working? See **[TROUBLESHOOTING.md](./TROUBLESHOOTING.md)** for a layer-by-layer diagnostic model (Infrastructure → Application → Identity) instead of chasing symptoms.

---

## Architecture

```
                     ┌──────────────────────────────────────────────────────┐
                     │              traffic-generator (in-cluster)           │
                     │    Continuous realistic load — always running         │
                     └────────────────────────┬─────────────────────────────┘
                                              │
                     ┌────────────────────────▼─────────────────────────────┐
                     │                  NGINX (reverse proxy)                │
                     └────────────────────────┬─────────────────────────────┘
                                              │
                     ┌────────────────────────▼─────────────────────────────┐
                     │            gateway-api  (Python / FastAPI)            │
                     │          REST API · OIDC auth middleware · :8080      │
                     └──────────────────┬───────────────────┬───────────────┘
                                        │                   │
          ┌─────────────────────────────▼──┐   ┌───────────▼────────────────────┐
          │  account-service               │   │  transaction-service            │
          │  Java / Spring Boot · :8081    │   │  Node.js / Express · :8082      │
          │  Account CRUD · balance        │   │  Payment initiation · ledger    │
          └────────────────┬───────────────┘   └──────────┬─────────────────────┘
                           │  JMS → fraud.score.queue      │  JMS → alert.queue
                           │                               │
                     ┌─────▼───────────────────────────────▼───────────────┐
                     │           ActiveMQ Artemis  (JMS 2.0 broker)         │
                     └────────────────┬──────────────────────┬──────────────┘
                                      │                      │
               ┌──────────────────────▼────┐    ┌───────────▼──────────────────┐
               │  fraud-detection (Python)  │    │  notification-service (Go)   │
               │  Async scoring consumer    │    │  Email / SMS stub consumer   │
               └───────────────────────────┘    └──────────────────────────────┘

                     ┌──────────────────────────────────────────────────────┐
                     │      batch-processor  (Java / Spring Batch)          │
                     │  Nightly reconciliation · end-of-day settlement       │
                     └──────────────────────────┬───────────────────────────┘
                                                │
                     ┌──────────────────────────▼───────────────────────────┐
                     │     PostgreSQL  (ledger DB)   Redis  (session cache)  │
                     └──────────────────────────────────────────────────────┘
```

---

## Services

| Service | Language | Port | Role |
|---|---|---|---|
| `gateway-api` | Python (FastAPI) | 8080 | Public REST API, OIDC auth, request routing |
| `account-service` | Java (Spring Boot) | 8081 | Account CRUD, balance enquiry, JMS producer |
| `transaction-service` | Node.js (Express) | 8082 | Payment initiation, ledger write, JMS producer |
| `fraud-detection` | Python | — | Async fraud scoring, JMS consumer |
| `notification-service` | Go | — | Async email/SMS stubs, JMS consumer |
| `batch-processor` | Java (Spring Batch) | — | Nightly reconciliation and settlement |
| `traffic-generator` | Python | — | In-cluster continuous load generator |

Supporting infrastructure:

| Component | Image | Purpose |
|---|---|---|
| PostgreSQL 15 | `postgres:15` | Primary ledger database |
| Redis 7 | `redis:7` | Session store and cache |
| ActiveMQ Artemis | `apache/activemq-artemis` | JMS 2.0 broker (mirrors IBM MQ / TIBCO patterns) |
| Keycloak | `quay.io/keycloak/keycloak:26.0` | OIDC for gateway-api |
| NGINX | `nginx:1.25` | Reverse proxy · frontend dashboard |

---

## Prerequisites

The app runs on Kubernetes. You need either a local cluster or an AWS account.

### Option A — Local Kubernetes (recommended)

| Tool | Install | Notes |
|---|---|---|
| **Docker Desktop** | Enable Kubernetes in Docker Desktop → Settings → Kubernetes | Simplest — images built locally are available in the cluster automatically. |
| **Rancher Desktop** | https://rancherdesktop.io | Good Docker Desktop alternative — images available automatically. |
| **kind** | `brew install kind && kind create cluster` | Kubernetes-in-Docker, popular for CI. |
| **k3d** | `brew install k3d && k3d cluster create finance` | k3s in Docker. Fast startup. |
| **minikube** | `brew install minikube && minikube start` | Feature-rich, good driver support. |

**Docker Desktop quickstart:**
```bash
# 1. Open Docker Desktop → Settings → Kubernetes → Enable Kubernetes → Apply
# 2. Install kubectl and helm
brew install kubectl helm
kubectl get nodes   # 1 node Ready
```

> **Image availability by tool:**
> - **Docker Desktop / Rancher Desktop** — images built with `docker build` are available inside the cluster immediately. No extra step needed.
> - **kind** — `kind load docker-image finance-sample-app-<svc>:latest`
> - **k3d** — `k3d image import finance-sample-app-<svc>:latest`
> - **minikube** — `minikube image load finance-sample-app-<svc>:latest`
> - **Colima (with Kubernetes)** — its k3s uses containerd, so import into the `k8s.io` namespace (not just Docker): `docker save finance-sample-app-<svc>:latest | colima ssh -- sudo ctr -n k8s.io image import -`

### Option B — AWS EKS

Additionally requires AWS CLI ≥ 2.x and an SSO profile (`aws configure sso`). See [AWS EKS section](#aws--eks-via-terraform).

### Common tools

```bash
brew install kubectl helm terraform
kubectl version --client && helm version && terraform version   # >= 1.5
```

---

## Credentials

All credentials for local development are pre-set in `deploy/kubernetes/base/02-secrets.yaml`. No manual substitution needed for the first run — just `make deploy-k8s`.

### Application credentials

| Component | What | Value | Used by |
|---|---|---|---|
| PostgreSQL | database | `ledger` | account-service, batch-processor |
| PostgreSQL | user | `finance` | account-service, batch-processor |
| PostgreSQL | password | `finance_dev_password` | account-service, batch-processor |
| ActiveMQ Artemis | user | `admin` | all JMS producers/consumers |
| ActiveMQ Artemis | password | `artemis_dev_password` | all JMS producers/consumers |
| Keycloak | admin user | `admin` | Keycloak admin console |
| Keycloak | admin password | `Finance@Admin2025!` | Keycloak admin console |
| Keycloak | finance realm client | `finance-gateway` | gateway-api, frontend dashboard |
| Keycloak | client secret | `FuX1ZIddFs02LzJT-s5MZufplT7SzGmflb42_6P8VcI` | gateway-api, frontend dashboard |

### Access URLs

| What | URL | Notes |
|---|---|---|
| **Finance dashboard** | `http://localhost:30080` | Login with any finance realm user below |
| **Keycloak admin console** | `https://localhost:30443/admin/master/console/#/finance` | Login as `admin` / `Finance@Admin2025!` |
| **Keycloak finance realm account** | `https://localhost:30443/realms/finance/account/` | Self-service account page for realm users |
| **ActiveMQ management console** | `kubectl port-forward svc/activemq-artemis 8161:8161 -n finance` then `http://localhost:8161` | Broker metrics and queue management (not proxied through nginx) |

> ⚠ **Self-signed certificate — accept it before logging in.** The Finance dashboard's login flow calls Keycloak directly at `https://localhost:30443`, which nginx serves with a self-signed cert (local-only — EKS uses a real ACM certificate instead, see [AWS EKS deployment](#aws-eks-via-terraform)). Before your first login attempt, visit `https://localhost:30443` in your browser and accept the security warning (**Advanced → Accept the Risk** in Firefox, **Advanced → Proceed** in Chrome). You only need to do this once per browser profile — skipping it makes dashboard login fail with a `NetworkError` / "Failed to fetch" style error. This does **not** affect the in-cluster traffic generator, which talks to Keycloak over plain HTTP via its ClusterIP service name and never goes through the self-signed HTTPS proxy.

### Finance realm users and roles

Pre-imported into the `finance` Keycloak realm. Log in via the Finance dashboard at `http://localhost:30080` — it redirects to Keycloak at `https://localhost:30443` automatically.

All users share the password **`Finance@2025!`**.

| Username | Role | Dashboard capabilities |
|---|---|---|
| `alice.analyst` | `finance-analyst` | View accounts list · Check balances · Read-only |
| `bob.trader` | `finance-trader` | Everything analyst can do · **Initiate payments** · **Initiate transfers** |
| `carol.admin` | `finance-admin` | Everything trader can do · **Make deposits** · **Approve/reject payments** · Create accounts |
| `dave.auditor` | `finance-auditor` | View accounts list · Check balances · Read-only |
| `eve.compliance` | `finance-compliance` | View accounts · **Approve or reject pending payments** |

#### What each dashboard card shows per role

| Dashboard card | analyst | trader | admin | auditor | compliance |
|---|---|---|---|---|---|
| Account list | ✅ | ✅ | ✅ | ✅ | ✅ |
| Balance check | ✅ | ✅ | ✅ | ✅ | ✅ |
| Initiate payment | ❌ | ✅ | ✅ | ❌ | ❌ |
| Initiate transfer | ❌ | ✅ | ✅ | ❌ | ❌ |
| Make deposit | ❌ | ❌ | ✅ | ❌ | ❌ |
| Payment validation | ❌ | ❌ | ✅ | ❌ | ✅ |

> **Security:** All values in `02-secrets.yaml` are development-only defaults — rotate everything before any staging or production deployment.

---

## Quick Start

```bash
# 1. Build all service images
make build

# 2. Load images into the cluster (skip this step on Docker Desktop / Rancher Desktop)
# kind:     kind load docker-image finance-sample-app-<svc>:latest
# k3d:      k3d image import finance-sample-app-<svc>:latest
# minikube: minikube image load finance-sample-app-<svc>:latest
# Colima:   docker save finance-sample-app-<svc>:latest | colima ssh -- sudo ctr -n k8s.io image import -

# 3. Deploy
make deploy-k8s
```

The stack is ready when all pods are Running:
```bash
kubectl get pods -n finance
```

Traffic starts flowing automatically from the in-cluster `traffic-generator` pod:
```bash
kubectl logs -n finance deploy/traffic-generator -f
```

**Finance dashboard:** `http://localhost:30080` — log in with any finance realm user (e.g. `carol.admin` / `Finance@2025!`).

**Keycloak admin console:** `https://localhost:30443/admin/master/console/#/finance` — log in as `admin` / `Finance@Admin2025!`.

See [Credentials](#credentials) for all users, roles, and URLs.

> #### ✅ Verify before continuing
> - [ ] `kubectl get pods -n finance` — all 12 pods `Running` (incl. `traffic-generator`)
> - [ ] `kubectl logs -n finance deploy/traffic-generator -f` — shows successful (non-401) requests
> - [ ] Finance dashboard loads at `http://localhost:30080` and login succeeds
>
> If the traffic generator logs show `401` / `invalid_client_credentials`, the
> `KEYCLOAK_CLIENT_SECRET` env var on the `traffic-generator` Deployment doesn't
> match the real `app-secrets` secret — check `kubectl get deployment
> traffic-generator -n finance -o yaml | grep -A3 KEYCLOAK_CLIENT_SECRET`.

---

## Datadog Observability (your task)

The app above runs with zero Datadog configuration. Your task: instrument it for full observability — APM, logs, RUM, DBM, ActiveMQ/JMS metrics, custom business metrics, monitors, SLOs, a dashboard, and synthetic tests. Use Datadog's own documentation, not this repo, as your reference. When you're done (or stuck), the reference solution lives on the `main` branch — diff against it, e.g.:

```bash
git diff partner-exercise main -- deploy/kubernetes/base/services/gateway-api.yaml
```

---

## Traffic Generator

Traffic is generated **automatically** by the `traffic-generator` Deployment running inside the cluster. It starts with the app and runs continuously — no scripts needed from your laptop.

Watch, pause, resume and tune the rate:

```bash
kubectl logs -n finance deploy/traffic-generator -f              # watch
kubectl scale deployment traffic-generator --replicas=0 -n finance   # pause
kubectl scale deployment traffic-generator --replicas=1 -n finance   # resume
```

Traffic mix:

| Scenario | Weight | Path |
|---|---|---|
| Balance check (JWT) | 30 % | gateway-api → account-service |
| Payment initiation (JWT) | 25 % | gateway-api → transaction-service → ActiveMQ |
| Account lookup (direct) | 20 % | account-service → PostgreSQL |
| Health checks | 10 % | all three HTTP services |
| Error cases (404 / 401 / 422) | 15 % | various |

---

## Testing everything manually

The fastest way to exercise the whole stack end-to-end. Every target is
idempotent — safe to re-run. For what "healthy" looks like at each phase, use the
**✅ Verify before continuing** checklist in [Quick Start](#quick-start).

### Local (Docker Desktop / Rancher / kind / k3d / minikube / Colima)

```bash
make build                     # build the 6 service images

# Load images into the cluster (see Prerequisites for your tool):
#   Docker Desktop / Rancher Desktop — automatic, skip this step
#   Colima (its Kubernetes uses containerd) — import into the k8s.io namespace:
#     for svc in gateway-api account-service transaction-service fraud-detection notification-service batch-processor; do \
#       docker save "finance-sample-app-${svc}:latest" | colima ssh -- sudo ctr -n k8s.io image import -; done
#   kind: kind load docker-image …   k3d: k3d image import …   minikube: minikube image load …

make deploy-k8s                # app + in-cluster traffic generator
kubectl get pods -n finance    # wait for all 12 pods Running

make test                      # scripted e2e test (needs a port-forward — see below)
make teardown                  # full local cleanup (namespaces + volumes)
```

### AWS EKS

```bash
aws sso login --profile <profile>
make tf-plan-aws && make tf-apply-aws            # provisions EKS/VPC/ECR/IAM/NLB (~15–20 min)
make tf-configure-kubectl && kubectl get nodes
eval "$(cd deploy/terraform/aws && terraform output -raw ecr_login_command)"
make build-ecr && make deploy-k8s-eks
# then point Keycloak at the NLB — run the numbered step 8 block under "AWS EKS via Terraform" below
make tf-destroy-aws                              # single-command teardown when done
```

### How to confirm it works

| Check | Where to look |
|---|---|
| App is serving traffic | `kubectl logs -n finance deploy/traffic-generator -f` — 200/201 responses, no 401 storms |
| Dashboard + login | `http://localhost:30080` (EKS: `cd deploy/terraform/aws && terraform output -raw frontend_url`) — log in as `carol.admin` / `Finance@2025!` |
| Scripted e2e test | `make test` (needs a port-forward to reach the services on localhost) |

---

## Deployment Targets

```
deploy/
  kubernetes/
    base/          K8s manifests shared by all targets
    overlays/eks/  Kustomize patches for EKS (ECR images, gp3 StorageClass)
  terraform/
    aws/           EKS + ECR + VPC + IAM
```

### Local Kubernetes (Docker Desktop / kind / k3d / minikube)

```bash
make build
# load images if needed — see Prerequisites above (skip on Docker Desktop)
make deploy-k8s       # deploys app + traffic-generator
make teardown         # full reset (namespaces + volumes)
```

### AWS EKS via Terraform

```bash
# 1. Authenticate
aws sso login --profile <your-profile>

# 2. Configure Terraform
cp deploy/terraform/aws/staging.tfvars.example deploy/terraform/aws/staging.tfvars
# edit: aws_profile, aws_region, cluster_name

# 3. Provision AWS infrastructure (~15–20 min)
#    Creates: EKS cluster, VPC, ECR repos, IAM roles
make tf-plan-aws
make tf-apply-aws

# 4. Configure kubectl
make tf-configure-kubectl
kubectl get nodes   # verify cluster is reachable

# 5. Build and push images to ECR (cross-compile for linux/amd64 on Apple Silicon)
eval "$(cd deploy/terraform/aws && terraform output -raw ecr_login_command)"
make build-ecr

# 6. (Optional) Configure a custom domain + ACM certificate for HTTPS on the NLB.
#    Without this, the dashboard is HTTP-only at the NLB hostname (fine for a demo).
#    Edit staging.tfvars: domain_name = "finance.example.com", then make tf-apply-aws,
#    then add a CNAME in your DNS: finance.example.com → <nlb-hostname>.
#    See deploy/terraform/aws/variables.tf for domain_name.

# 7. Deploy the app to EKS (generates the Kustomize overlay from live Terraform
#    output — ECR image URLs, ACM cert annotations if domain_name is set)
make deploy-k8s-eks

# 8. Point Keycloak's public URL at the Terraform-managed NLB.
#    The NLB (aws_lb.frontend) was already created in step 3, so its hostname is
#    known immediately — no waiting for AWS to assign a LoadBalancer hostname like
#    the old Kubernetes-provisioned ELB required.
FE_URL=$(cd deploy/terraform/aws && terraform output -raw frontend_url)
kubectl patch configmap app-config -n finance --type=merge \
  -p "{\"data\":{\"KEYCLOAK_PUBLIC_URL\":\"$FE_URL\"}}"
sed "s|https://localhost:30443|$FE_URL|g" frontend-stub/index.html > /tmp/finance-index.html
kubectl create configmap frontend-dashboard --from-file=index.html=/tmp/finance-index.html \
  -n finance --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/keycloak deployment/frontend -n finance
# Dashboard: terraform output -raw frontend_url
# Keycloak (self-signed passthrough, always available): terraform output -raw frontend_keycloak_https_url

# 9. Tear down when done
make tf-destroy-aws   # single-pass terraform destroy — see below for why this is now reliable
```

#### Teardown is reliable — no manual ELB cleanup needed

`make tf-destroy-aws` (→ `scripts/aws-force-destroy.sh`) handles dependency ordering automatically:

| Step | Action | Why |
|---|---|---|
| 0 | Best-effort ELB/security-group safety net | Defense-in-depth only — normally a no-op (see below) |
| 1 | Delete EKS node groups via CLI | Avoids `ResourceInUseException` |
| 2 | Delete EKS add-ons via CLI | Required before cluster deletion |
| 3 | Delete EKS cluster | |
| 4 | Delete ECR repositories | |
| 5 | `terraform destroy` | VPC, subnets, IAM, KMS, CloudWatch, the frontend NLB, target groups |

> **Why teardown no longer needs manual ELB cleanup:** the `frontend` Service is `type: NodePort` on both local and EKS — it never calls the AWS API. Public exposure is handled entirely by `aws_lb.frontend`, a first-class Terraform resource, so `terraform destroy` always finds and removes it in the correct dependency order. This replaced an older design where `type: LoadBalancer` let Kubernetes' cloud-controller-manager silently create a Classic ELB that Terraform never tracked — if the EKS cluster was deleted first, that ELB (and its security group) became permanently orphaned and blocked VPC/subnet deletion. Step 0 above is kept purely as a defense-in-depth safety net in case a future change reintroduces a `LoadBalancer` Service elsewhere.

---

## Teardown (local)

```bash
make teardown
```

Removes: finance namespace (including all PVCs) and any orphaned Docker volumes from previous Compose runs.

Start fresh after:
```bash
make build && make deploy-k8s
```

---

## Security Notes

- **Secrets:** All values in `deploy/kubernetes/base/02-secrets.yaml` are development-only defaults — rotate before any staging or production use.
- **PII masking:** Financial data (card numbers, IBANs, account balances) must not appear in log messages. Mask or redact sensitive fields before logging in production.
- **Keycloak:** Sample passwords in `identity-provider/realm-export/` are for development only. Rotate before any staging or production use.

---

## Identity Provider

Keycloak **26.0** provides:
- **OIDC for gateway-api** — JWT Bearer token validation per request
- **Finance roles** — `finance-analyst`, `finance-trader`, `finance-admin`, `finance-auditor`, `finance-compliance`

Keycloak is proxied through **nginx over HTTPS** on port **30443** — nginx terminates TLS with a self-signed certificate and forwards plain HTTP to `keycloak:8080` internally. This allows Keycloak 26 to set `Secure` session cookies correctly (required by browsers).

> **First visit:** browsers will show a security warning for the self-signed certificate at `https://localhost:30443`. Click **Advanced → Accept the Risk** (Firefox) or **Advanced → Proceed** (Chrome) once — you won't be asked again.

`KEYCLOAK_PUBLIC_URL` in `deploy/kubernetes/base/01-config.yaml` is the single source of truth for Keycloak's public URL. It is used by `KC_HOSTNAME_URL` on the Keycloak pod and injected into the finance dashboard at deploy time. On EKS, patch it to the NLB hostname after deploy (see AWS EKS workflow above).

| URL | Credentials |
|---|---|
| **Admin console:** `https://localhost:30443/admin/master/console/#/finance` | `admin` / `Finance@Admin2025!` |
| **Realm account page:** `https://localhost:30443/realms/finance/account/` | any finance realm user |

Full guide: `identity-provider/README.md`
