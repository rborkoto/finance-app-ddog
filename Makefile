# Meridian Financial - sample app for the Datadog partner take-home exercise
#
# This Makefile builds and deploys the APPLICATION only. Nothing here installs
# or configures Datadog: the Agent, instrumentation, and Datadog resources are
# the exercise, and you do them yourself (see README.md).
#
# Run 'make help' for every target with a one-line description.
#
# Local workflow:
#   make build          # build all service images
#   make deploy-k8s     # deploy the app + in-cluster traffic generator
#   make teardown       # full reset
#
# AWS EKS workflow (optional):
#   aws sso login --profile <profile>
#   make tf-plan-aws && make tf-apply-aws
#   make tf-configure-kubectl
#   make build-ecr
#   make deploy-k8s-eks

.PHONY: all build build-ecr version test test-traffic deploy-k8s check-eks-kubeconfig deploy-k8s-eks undeploy-k8s teardown tf-plan-aws tf-apply-aws tf-configure-kubectl frontend-url tf-destroy-aws scenario-1 unscenario-1 scenario-2 unscenario-2 scenario-3 unscenario-3 help

# Image version: the git short SHA, or 'dev' if git is unavailable.

DD_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo 'dev')


# FE_URL/DASH_URL: optional, EKS-only. Export these (from 'terraform output',
# see the AWS + K8s workflow above) before 'make deploy-k8s-eks' so Keycloak's
# public URL and the finance-gateway client's allowed origins are correct on
# the very first deploy -- no post-deploy patch or pod restart needed. Never
# set locally: 'make deploy-k8s' always uses the checked-in localhost values.
FE_URL ?=
DASH_URL ?=

# ── Reusable canned recipes ───────────────────────────────────────────
# Expanded inline inside recipes with $(macro_name). Each keeps its own
# backslash continuations so it slots into a single recipe shell.


# Create the keycloak-tls Secret (self-signed) unless it already exists.
define ensure_keycloak_tls
	if ! kubectl get secret keycloak-tls -n finance >/dev/null 2>&1; then \
		openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
			-keyout /tmp/keycloak-tls.key \
			-out /tmp/keycloak-tls.crt \
			-subj "/CN=localhost/O=finance-sample-app" \
			-addext "subjectAltName=DNS:localhost,DNS:keycloak,IP:127.0.0.1" \
			2>/dev/null; \
		kubectl create secret tls keycloak-tls \
			--cert=/tmp/keycloak-tls.crt \
			--key=/tmp/keycloak-tls.key \
			-n finance; \
		rm -f /tmp/keycloak-tls.crt /tmp/keycloak-tls.key; \
		echo "  ✓ keycloak-tls Secret created"; \
	else \
		echo "  keycloak-tls Secret already exists — skipping"; \
	fi
endef

# Create the keycloak-realm-import ConfigMap from the realm export dir.
# On EKS, if FE_URL/DASH_URL are set (see deploy-k8s-eks), append the real
# Keycloak/dashboard origins to redirectUris/webOrigins in a templated copy
# so the finance-gateway client is correct from Keycloak's first boot --
# no live kcadm patch needed afterward. Local's checked-in localhost entries
# stay untouched either way (FE_URL/DASH_URL are never set for 'deploy-k8s').
define create_realm_cm
	if [ -n "$$FE_URL" ] && [ -n "$$DASH_URL" ]; then \
		rm -rf /tmp/finance-realm-import; \
		mkdir -p /tmp/finance-realm-import; \
		cp identity-provider/realm-export/*.json /tmp/finance-realm-import/; \
		sed -i.bak \
			-e "s|\"https://localhost:30443/\*\"|&,\n        \"$$FE_URL/*\"|" \
			-e "s|\"http://localhost:30080/\*\"|&,\n        \"$$DASH_URL/*\"|" \
			-e "s|\"https://localhost:30443\"|&,\n        \"$$FE_URL\"|" \
			-e "s|\"http://localhost:30080\"|&,\n        \"$$DASH_URL\"|" \
			/tmp/finance-realm-import/finance-realm.json; \
		rm -f /tmp/finance-realm-import/*.bak; \
		kubectl create configmap keycloak-realm-import \
			--from-file=/tmp/finance-realm-import/ \
			-n finance --dry-run=client -o yaml | kubectl apply -f -; \
		rm -rf /tmp/finance-realm-import; \
	else \
		kubectl create configmap keycloak-realm-import \
			--from-file=identity-provider/realm-export/ \
			-n finance --dry-run=client -o yaml | kubectl apply -f -; \
	fi
endef

# Create the traffic-generator-script ConfigMap.
define create_traffic_cm
	kubectl create configmap traffic-generator-script \
		--from-file=generate-traffic.py=scripts/generate-traffic.py \
		-n finance --dry-run=client -o yaml | kubectl apply -f -
endef

# Build the frontend-dashboard ConfigMap, injecting KEYCLOAK_PUBLIC_URL.
# Prefers the FE_URL env var (set for EKS, see deploy-k8s-eks) over the
# checked-in default so the dashboard stub is correct from the first deploy.
define create_frontend_cm
	KEYCLOAK_URL=$${FE_URL:-$$(grep 'KEYCLOAK_PUBLIC_URL' deploy/kubernetes/base/01-config.yaml | sed 's/.*: *"\(.*\)"/\1/')}; \
	sed "s|https://localhost:30443|$$KEYCLOAK_URL|g" frontend-stub/index.html > /tmp/finance-index.html; \
	kubectl create configmap frontend-dashboard \
		--from-file=index.html=/tmp/finance-index.html \
		-n finance --dry-run=client -o yaml | kubectl apply -f -; \
	rm -f /tmp/finance-index.html
endef
# ──────────────────────────────────────────────────────────────────────

all: build

## help: [Misc] Show this help message (all available make targets with descriptions).
help:
	@echo "Meridian Financial - sample app (application only, no Datadog)"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@awk '/^## [a-zA-Z0-9_-]+:/ { \
			sub(/^## /, ""); \
			split($$0, a, ":"); \
			target=a[1]; \
			sub(/^[^:]*: */, ""); \
			desc=$$0; \
			cat="Misc"; \
			if (match(desc, /^\[[A-Za-z0-9 &\/]+\]/)) { \
				cat=substr(desc, RSTART+1, RLENGTH-2); \
				desc=substr(desc, RSTART+RLENGTH); \
				sub(/^ +/, "", desc); \
			} \
			lines[cat]=lines[cat] sprintf("  \033[36m%-24s\033[0m %s\n", target, desc); \
		} \
		END { \
			n=split("Misc,Build & Test,Local Kubernetes,AWS / Terraform,Workshop Scenarios", order, ","); \
			for (i=1; i<=n; i++) { \
				c=order[i]; \
				if (lines[c] != "") { \
					printf "\033[1m%s\033[0m\n", c; \
					printf "%s", lines[c]; \
					printf "\n"; \
				} \
			} \
		}' $(MAKEFILE_LIST)

## version: [Misc] Print the image version (git short SHA) used to tag images.
version:
	@echo "DD_VERSION=$(DD_VERSION)"

## build: [Build & Test] Build all service images for the local platform.
##        Images are tagged finance-sample-app-<service>:latest and :<DD_VERSION> (git short SHA).
##        Docker Desktop / Rancher Desktop: images are available in the cluster immediately.
##        Other tools — load after building:
##          kind:     kind load docker-image finance-sample-app-<svc>:latest
##          k3d:      k3d image import finance-sample-app-<svc>:latest
##          minikube: minikube image load finance-sample-app-<svc>:latest
##        Then rolling-restart to pick up new images:
##          kubectl rollout restart deployment -n finance
build:
	@echo "Building all service images (DD_VERSION=$(DD_VERSION))..."
	@for svc in gateway-api account-service transaction-service fraud-detection notification-service batch-processor; do \
		echo "  → $$svc"; \
		docker build -t finance-sample-app-$$svc:latest \
		             -t finance-sample-app-$$svc:$(DD_VERSION) \
		             --build-arg DD_VERSION=$(DD_VERSION) \
		             ./$$svc || { echo "✗ $$svc failed to build"; exit 1; }; \
	done
	@echo ""
	@echo "✓ All images built. To deploy to local k3s:"
	@echo "  # Docker Desktop/Rancher Desktop: images available immediately — no load step needed."
	@echo "  # kind:     kind load docker-image finance-sample-app-<svc>:latest"
	@echo "  # k3d:      k3d image import finance-sample-app-<svc>:latest"
	@echo "  # minikube: minikube image load finance-sample-app-<svc>:latest"
	@echo "  kubectl rollout restart deployment -n finance"

## build-ecr: [Build & Test] Build all service images for linux/amd64 and push directly to ECR.
##            Use this when deploying to EKS from an Apple Silicon (ARM) Mac.
##            Requires: ECR login (eval "$(cd deploy/terraform/aws && terraform output -raw ecr_login_command)")
##            Uses Docker Buildx cross-compilation — no QEMU emulation, safe on ARM.
##            Requires: terraform apply must have completed (make tf-apply-aws)
build-ecr:
	@if [ ! -f deploy/terraform/aws/staging.tfvars ]; then \
		echo "Error: deploy/terraform/aws/staging.tfvars not found."; \
		echo "       Copy staging.tfvars.example and fill in your values first."; \
		exit 1; \
	fi
	@cd deploy/terraform/aws && terraform output ecr_registry_urls >/dev/null 2>&1 || { \
		echo "Error: terraform output ecr_registry_urls failed."; \
		echo "       Run 'make tf-apply-aws' before 'make build-ecr'."; \
		exit 1; \
	}
	@ECR_URLS=$$(cd deploy/terraform/aws && terraform output -json ecr_registry_urls); \
	for SVC in gateway-api account-service transaction-service fraud-detection notification-service batch-processor; do \
		ECR_URL=$$(echo "$$ECR_URLS" | python3 -c "import sys,json; print(json.load(sys.stdin)['$$SVC'])"); \
		echo "Building $$SVC -> $$ECR_URL"; \
		docker buildx build --platform linux/amd64 --push \
			-t $${ECR_URL}:$(DD_VERSION) \
			-t $${ECR_URL}:latest \
			./$$SVC; \
	done

## test: [Build & Test] Run the e2e test suite against the running stack.
##       Prerequisites: make deploy-k8s (uses Python stdlib only — no pip install required).
##       Note: requires kubectl port-forward or NodePort access to the services.
##       For a no-setup check, watch the in-cluster traffic generator instead:
##         kubectl logs -n finance deploy/traffic-generator -f
test:
	python3 scripts/test-e2e.py

## test-traffic: [Build & Test] Run the traffic generator locally for a fixed duration.
##               The in-cluster traffic-generator Deployment already runs continuously.
##               Use this to temporarily boost traffic or test from your laptop.
##               Note: requires services reachable on localhost (kubectl port-forward).
test-traffic:
	python3 scripts/generate-traffic.py --rate 2 --duration 60



## deploy-k8s: [Local Kubernetes] Deploy the Finance app to Kubernetes (application only).
##             Creates the 'finance' namespace and all infrastructure + application services.
##             Prerequisites:
##               1. make build        — build all service images
##               2. kubectl configured — pointing at your target cluster
##             On Docker Desktop / Rancher Desktop, images built by
##             'make build' are immediately available (imagePullPolicy: IfNotPresent).
##             On kind/k3d/minikube, load images after building (see 'make build' help).
deploy-k8s:
	@echo "Creating finance namespace (idempotent)..."
	kubectl apply -f deploy/kubernetes/base/00-namespace.yaml
	@echo "Creating Keycloak realm ConfigMap..."
	@$(create_realm_cm)
	@echo "Creating TLS secret for nginx Keycloak HTTPS proxy..."
	@$(ensure_keycloak_tls)
	@echo "Applying config, secrets and infrastructure..."
	kubectl apply -f deploy/kubernetes/base/01-config.yaml
	kubectl apply -f deploy/kubernetes/base/02-secrets.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/activemq-broker-config.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/activemq.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/keycloak.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/postgres-init.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/postgres.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/redis.yaml
	@echo "Waiting for PostgreSQL to be ready..."
	kubectl rollout status statefulset/postgres-ledger -n finance --timeout=120s
	@echo "Creating traffic-generator script ConfigMap..."
	@$(create_traffic_cm)
	@echo "Creating frontend dashboard ConfigMap (injecting KEYCLOAK_PUBLIC_URL)..."
	@$(create_frontend_cm)
	@echo "Applying application services..."
	@for f in account-service batch-processor fraud-detection frontend gateway-api notification-service transaction-service traffic-generator; do \
		echo "  → $$f"; \
		kubectl apply -f deploy/kubernetes/base/services/$$f.yaml; \
	done
	@echo ""
	@echo "✓  Deployed. Check pod status:"
	@echo "     kubectl get pods -n finance"
	@echo "   Dashboard available at: http://localhost:30080"
	@echo "   (or: kubectl port-forward svc/frontend 3000:80 -n finance)"
	@echo ""
	@echo "⚠  Keycloak on :30443 uses a self-signed HTTPS cert (local-only —"
	@echo "   EKS uses a real ACM cert instead). Before your first login on the"
	@echo "   dashboard, open https://localhost:30443 once and accept the browser"
	@echo "   security warning (Advanced → Accept the Risk in Firefox, Advanced →"
	@echo "   Proceed in Chrome). Skipping this makes dashboard login fail with a"
	@echo "   network/fetch error. This only affects browser access — the in-cluster"
	@echo "   traffic-generator talks to Keycloak over plain HTTP and is unaffected."

## check-eks-kubeconfig: [AWS / Terraform] Verify kubectl can actually reach the EKS cluster,
##                       auto-refreshing via tf-configure-kubectl if not. kubeconfig stores a
##                       static snapshot of the cluster's API endpoint — if the cluster was
##                       destroyed and recreated (even under the same name) since kubeconfig
##                       was last written, that endpoint is dead (DNS no longer resolves) and
##                       nothing detects it automatically. This makes that self-healing.
check-eks-kubeconfig:
	@if ! kubectl get nodes --request-timeout=5s >/dev/null 2>&1; then \
		echo "    kubectl can't reach the cluster (stale kubeconfig?) — refreshing via tf-configure-kubectl..."; \
		$(MAKE) tf-configure-kubectl; \
		if ! kubectl get nodes --request-timeout=5s >/dev/null 2>&1; then \
			echo "    ERROR: still can't reach the EKS cluster after refreshing kubeconfig."; \
			echo "           Check that 'make tf-apply-aws' has completed and your AWS SSO session is still valid."; \
			exit 1; \
		fi; \
	fi

## deploy-k8s-eks: [AWS / Terraform] Deploy to EKS using Kustomize overlay.
##                 Patches base manifests with ECR image URLs, gp3 StorageClass,
##                 and imagePullPolicy:Always. Safe to re-run (idempotent).
##                 Prerequisites: make tf-apply-aws, make build-ecr. (kubeconfig freshness
##                 is checked automatically via check-eks-kubeconfig.)
##                 Export FE_URL and DASH_URL first (see README's AWS EKS walkthrough) to
##                 get a working Keycloak login on the very first deploy — no post-deploy
##                 patch or restart needed. Without them, see the fallback instructions
##                 printed at the end of this target.
deploy-k8s-eks: check-eks-kubeconfig
	bash scripts/generate-eks-kustomization.sh
	@echo "Creating finance namespace (idempotent)..."
	kubectl apply -f deploy/kubernetes/base/00-namespace.yaml
	@echo "Creating Keycloak realm ConfigMap..."
	@FE_URL="$(FE_URL)" DASH_URL="$(DASH_URL)"; $(create_realm_cm)
	@echo "Applying config and secrets..."
	kubectl apply -f deploy/kubernetes/base/01-config.yaml
	@if [ -n "$(FE_URL)" ]; then \
		echo "FE_URL set — patching app-config's KEYCLOAK_PUBLIC_URL before Keycloak starts..."; \
		kubectl patch configmap app-config -n finance --type=merge -p "{\"data\":{\"KEYCLOAK_PUBLIC_URL\":\"$(FE_URL)\"}}"; \
	fi
	kubectl apply -f deploy/kubernetes/base/02-secrets.yaml
	@echo "Creating traffic-generator script ConfigMap..."
	@$(create_traffic_cm)
	@echo "Creating TLS secret for nginx Keycloak HTTPS proxy (idempotent)..."
	@$(ensure_keycloak_tls)
	@echo "Creating frontend dashboard ConfigMap (injecting current KEYCLOAK_PUBLIC_URL)..."
	@FE_URL="$(FE_URL)" $(create_frontend_cm)
	@echo "Applying EKS overlay (ECR images + gp3 StorageClass + infrastructure + services)..."
	kubectl kustomize deploy/kubernetes/overlays/eks | kubectl apply -f -
	@echo "Waiting for PostgreSQL to be ready..."
	kubectl rollout status statefulset/postgres-ledger -n finance --timeout=120s
	@echo ""
	@echo "✓  Deployed. Check pod status:"
	@echo "     kubectl get pods -n finance"
	@echo ""
ifneq ($(strip $(FE_URL)),)
ifneq ($(strip $(DASH_URL)),)
	@echo "✓  FE_URL/DASH_URL were set, so KEYCLOAK_PUBLIC_URL and the Keycloak"
	@echo "   client's redirectUris/webOrigins were templated in before Keycloak's"
	@echo "   first boot — no further patching or restart needed. Just accept the"
	@echo "   certificate warning in your browser if you're on Option A (self-signed)."
else
	@echo "⚠  FE_URL was set but DASH_URL was not — app-config's KEYCLOAK_PUBLIC_URL"
	@echo "   is correct, but the Keycloak client's redirectUris/webOrigins were NOT"
	@echo "   templated (create_realm_cm needs both). Export DASH_URL too and re-run"
	@echo "   'make deploy-k8s-eks', or patch the live realm manually — see"
	@echo "   README.md's 'Update the Keycloak client's allowed origins' section."
endif
else
	@echo "⚠  Keycloak public URL (always required): FE_URL/DASH_URL were not set for"
	@echo "   this deploy, so app-config still has the default localhost value and the"
	@echo "   Keycloak client's redirectUris/webOrigins are still localhost-only."
	@echo "   The frontend Service (nginx) sits behind the Terraform-managed NLB and"
	@echo "   proxies Keycloak — the keycloak Service itself is ClusterIP-only, so"
	@echo "   Keycloak is NEVER reached via frontend_url — nginx only proxies Keycloak"
	@echo "   on its own dedicated listener(s), not the dashboard's (see"
	@echo "   deploy/kubernetes/base/services/frontend.yaml's routing table)."
	@echo "   Tip: next time, export FE_URL/DASH_URL before running 'make deploy-k8s-eks'"
	@echo "   to skip this whole patch+restart dance. For now, fix the live cluster:"
	@echo "     FE_URL=\$$(cd deploy/terraform/aws && terraform output -raw frontend_keycloak_https_url)  # Option A: self-signed"
	@echo "     # FE_URL=\$$(cd deploy/terraform/aws && terraform output -raw frontend_keycloak_acm_url)  # Option B/C: custom domain — use this line instead"
	@echo "     kubectl patch configmap app-config -n finance --type=merge -p \"{\\\"data\\\":{\\\"KEYCLOAK_PUBLIC_URL\\\":\\\"\$$FE_URL\\\"}}\""
	@echo "     sed \"s|https://localhost:30443|\$$FE_URL|g\" frontend-stub/index.html > /tmp/finance-index.html"
	@echo "     kubectl create configmap frontend-dashboard --from-file=index.html=/tmp/finance-index.html -n finance --dry-run=client -o yaml | kubectl apply -f -"
	@echo "     kubectl rollout restart deployment/keycloak deployment/frontend -n finance"
	@echo ""
	@echo "⚠  Keycloak client redirect URIs (also always required, for both"
	@echo "   options): identity-provider/realm-export/finance-realm.json"
	@echo "   hardcodes localhost origins. Without this step, login fails with"
	@echo "   'NetworkError' (Keycloak rejects the OIDC redirect/CORS from an"
	@echo "   unlisted origin) regardless of which certificate option you're"
	@echo "   using — this is CORS allow-listing, unrelated to the cert."
	@echo "   Patch the live realm via kcadm (uses the same FE_URL from above,"
	@echo "   plus \$$(terraform output -raw frontend_url) for the dashboard's"
	@echo "   own origin):"
	@echo "     DASH_URL=\$$(cd deploy/terraform/aws && terraform output -raw frontend_url)"
	@echo "     KC_POD=\$$(kubectl get pod -n finance -l app=keycloak -o jsonpath='{.items[0].metadata.name}')"
	@echo "     kubectl exec -n finance \"\$$KC_POD\" -- /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password 'Finance@Admin2025!'"
	@echo "     CLIENT_ID=\$$(kubectl exec -n finance \"\$$KC_POD\" -- /opt/keycloak/bin/kcadm.sh get clients -r finance -q clientId=finance-gateway --fields id --format csv --noquotes)"
	@echo "     kubectl exec -n finance \"\$$KC_POD\" -- /opt/keycloak/bin/kcadm.sh update \"clients/\$$CLIENT_ID\" -r finance \\"
	@echo "       -s 'redirectUris=[\"http://localhost:30080/*\",\"https://localhost:30443/*\",\"http://gateway-api:8080/*\",\"'\"\$$DASH_URL\"'/*\",\"'\"\$$FE_URL\"'/*\"]' \\"
	@echo "       -s 'webOrigins=[\"http://localhost:30080\",\"https://localhost:30443\",\"http://gateway-api:8080\",\"'\"\$$DASH_URL\"'\",\"'\"\$$FE_URL\"'\"]'"
endif

## undeploy-k8s: [Local Kubernetes] Remove all Finance app resources from Kubernetes (namespaces only).
##               Does NOT delete persistent data — use 'make teardown' for a full reset.
undeploy-k8s:
	kubectl delete namespace finance --ignore-not-found
	kubectl delete namespace datadog --ignore-not-found
	# gp3 is cluster-scoped (not namespaced) — must be deleted separately
	kubectl delete storageclass gp3 --ignore-not-found

## teardown: [Local Kubernetes] Full reset — removes all K8s resources AND cleans up persistent data.
##           Deletes:
##             - finance namespace (all app pods, services, configmaps)
##             - datadog namespace and a 'datadog-operator' Helm release, IF you
##               installed Datadog under those names during the exercise
##             - Any leftover Docker volumes (postgres, redis, artemis, keycloak)
##             - Port-forward processes
##           Safe to run even if some resources are already gone.
##
##           After teardown, start fresh with:
##             make build && make deploy-k8s
teardown:
	@echo "==> Killing any stray kubectl port-forward processes..."
	@pkill -f 'kubectl port-forward' 2>/dev/null || true
	@echo "==> Removing Datadog Agent CRD instance..."
	@kubectl delete datadogagent datadog -n datadog --ignore-not-found 2>&1 || true
	@echo "==> Deleting finance namespace (app pods, PVCs, services)..."
	@kubectl delete namespace finance --ignore-not-found 2>&1
	@echo "==> Deleting datadog namespace (Agent DaemonSet, Cluster Agent)..."
	@kubectl delete namespace datadog --ignore-not-found 2>&1
	@echo "==> Uninstalling Datadog Operator Helm release..."
	@helm uninstall datadog-operator -n datadog 2>/dev/null || true
	@echo "==> Removing leftover Docker volumes..."
	@for vol in postgres-data redis-data artemis-data keycloak-data datadog-run; do \
		docker volume rm finance-sample-app_$$vol 2>/dev/null && echo "  removed finance-sample-app_$$vol" || true; \
	done
	@# gp3 is cluster-scoped (EKS only) — safe to ignore if not present
	@kubectl delete storageclass gp3 --ignore-not-found 2>/dev/null || true
	@echo ""
	@echo "✓  Teardown complete. Cluster and data are clean."
	@echo "   Start fresh: make build && make deploy-k8s"

## deploy/terraform/aws/staging.tfvars: auto-created from staging.tfvars.example
##                                       on first use (self-heals a missing file
##                                       instead of failing 'terraform plan/apply'
##                                       with a raw "Failed to read variables file").
deploy/terraform/aws/staging.tfvars:
	@cp deploy/terraform/aws/staging.tfvars.example $@
	@echo "==> Created $@ from staging.tfvars.example"
	@echo "    Edit it with your aws_profile / aws_region / cluster_name, then re-run."

## tf-plan-aws: [AWS / Terraform] Initialise and plan the Terraform AWS (EKS) target.
##              Uses the AWS_PROFILE env var. Override vars: TF_AWS_VARS="-var-file=staging.tfvars -var aws_profile=<name>"
TF_AWS_VARS ?= -var-file=staging.tfvars
tf-plan-aws: deploy/terraform/aws/staging.tfvars
	cd deploy/terraform/aws && terraform init && terraform plan $(TF_AWS_VARS)

## tf-apply-aws: [AWS / Terraform] Apply the Terraform AWS plan (creates EKS, ECR, VPC, IAM).
##               WARNING: this provisions real AWS resources and incurs cost.
tf-apply-aws: deploy/terraform/aws/staging.tfvars
	bash scripts/aws-pre-apply.sh
	cd deploy/terraform/aws && terraform init && terraform apply $(TF_AWS_VARS)

## tf-configure-kubectl: [AWS / Terraform] Update kubeconfig to point kubectl at the EKS cluster.
##                       Run after tf-apply-aws before deploy-k8s.
tf-configure-kubectl:
	eval "$$(cd deploy/terraform/aws && terraform output -raw kubeconfig_command)"

## frontend-url: [AWS / Terraform] Print the public URL of the Finance app frontend on EKS.
##               Available as soon as make tf-apply-aws completes (Terraform-managed
##               NLB, not a Kubernetes LoadBalancer Service) — no need to deploy the
##               app first.
frontend-url:
	@cd deploy/terraform/aws && terraform output -raw frontend_url 2>/dev/null && echo "" \
		|| echo "No NLB yet — run 'make tf-apply-aws' first."

## tf-destroy-aws: [AWS / Terraform] Safely destroy all AWS resources created by Terraform.
##                 EKS node groups/add-ons/cluster, Secrets Manager secrets, and ECR
##                 repos are all Terraform-managed and destroy correctly on their own
##                 (module-ordered dependencies, recovery_window_in_days = 0,
##                 force_delete = true respectively). The only thing outside
##                 Terraform's state is stray, non-Terraform ELBs/ENIs, so this:
##                   1. Clears finance workloads via kubectl (best-effort) and
##                      releases any stray ELB/ENI in the VPC, excluding the
##                      Terraform-managed frontend NLB
##                   2. Runs terraform destroy for everything else
tf-destroy-aws:
	bash scripts/aws-force-destroy.sh --yes



## scenario-1: [Workshop Scenarios] Inject diagnosis Scenario 1 (see README, "Diagnosis exercises").
##             Changes the database underneath the app. Idempotent: tracked via
##             .scenario-1-applied. Reverse with make unscenario-1.
scenario-1:
	@if [ -f .scenario-1-applied ]; then \
		echo "Scenario 1 already injected. Run 'make unscenario-1' first to reapply."; \
	elif ! kubectl get statefulset postgres-ledger -n finance >/dev/null 2>&1; then \
		echo "postgres-ledger not found in namespace finance — run 'make deploy-k8s' first."; \
	else \
		echo "Injecting Scenario 1 on postgres-ledger..."; \
		if kubectl exec -i -n finance statefulset/postgres-ledger -- \
			psql -U finance -d ledger -v ON_ERROR_STOP=1 -f - < scripts/scenarios/scenario1-drop-index.sql; then \
			touch .scenario-1-applied; \
			echo ""; \
			echo "✓ Scenario 1 injected. Customers report slow payment confirmations."; \
			echo "  Use your Datadog setup to find out why."; \
		else \
			echo "⚠  SQL failed — check postgres-ledger is Ready."; \
		fi; \
	fi

## unscenario-1: [Workshop Scenarios] Reset Scenario 1.
unscenario-1:
	@if [ ! -f .scenario-1-applied ]; then \
		echo "Scenario 1 is not currently injected (nothing to reset)."; \
	else \
		echo "Resetting Scenario 1 on postgres-ledger..."; \
		if kubectl exec -i -n finance statefulset/postgres-ledger -- \
			psql -U finance -d ledger -v ON_ERROR_STOP=1 -f - < scripts/scenarios/scenario1-restore-index.sql; then \
			rm -f .scenario-1-applied; \
			echo "✓ Scenario 1 reset."; \
		else \
			echo "⚠  SQL failed — check postgres-ledger is Ready."; \
		fi; \
	fi

## scenario-2: [Workshop Scenarios] Inject diagnosis Scenario 2 (see README, "Diagnosis exercises").
##             Changes batch-processor's configuration and restarts it. Trigger a
##             reconciliation run with:
##               kubectl port-forward deploy/batch-processor 8083:8083 -n finance
##               curl -s -X POST localhost:8083/jobs/reconciliation   # in a second terminal
##             Idempotent: tracked via .scenario-2-applied. Reverse with make unscenario-2.
scenario-2:
	@if [ -f .scenario-2-applied ]; then \
		echo "Scenario 2 already injected. Run 'make unscenario-2' first to reapply."; \
	elif ! kubectl get deployment batch-processor -n finance >/dev/null 2>&1; then \
		echo "batch-processor deployment not found in namespace finance — run 'make deploy-k8s' first."; \
	else \
		kubectl set env deployment/batch-processor -n finance RECONCILIATION_SCENARIO_ENABLED=true; \
		kubectl rollout restart deployment/batch-processor -n finance; \
		touch .scenario-2-applied; \
		echo ""; \
		echo "✓ Scenario 2 injected. Finance says last night's reconciliation looks wrong,"; \
		echo "  but the job reported success. Trigger a run (see 'make help') and investigate."; \
	fi

## unscenario-2: [Workshop Scenarios] Reset Scenario 2.
unscenario-2:
	@if [ ! -f .scenario-2-applied ]; then \
		echo "Scenario 2 is not currently injected (nothing to reset)."; \
	else \
		kubectl set env deployment/batch-processor -n finance RECONCILIATION_SCENARIO_ENABLED-; \
		kubectl rollout restart deployment/batch-processor -n finance; \
		rm -f .scenario-2-applied; \
		echo "✓ Scenario 2 reset."; \
	fi

## scenario-3: [Workshop Scenarios] Inject diagnosis Scenario 3 (see README, "Diagnosis exercises").
##             Changes transaction-service's configuration and restarts it.
##             Idempotent: tracked via .scenario-3-applied. Reverse with make unscenario-3.
scenario-3:
	@if [ -f .scenario-3-applied ]; then \
		echo "Scenario 3 already injected. Run 'make unscenario-3' first to reapply."; \
	elif ! kubectl get deployment transaction-service -n finance >/dev/null 2>&1; then \
		echo "transaction-service deployment not found in namespace finance — run 'make deploy-k8s' first."; \
	else \
		kubectl set env deployment/transaction-service -n finance FRAUD_QUEUE_DUPLICATE_FACTOR=3; \
		kubectl rollout restart deployment/transaction-service -n finance; \
		touch .scenario-3-applied; \
		echo ""; \
		echo "✓ Scenario 3 injected. Fraud alerts are arriving long after each payment."; \
		echo "  Use your Datadog setup to find which service is responsible."; \
	fi

## unscenario-3: [Workshop Scenarios] Reset Scenario 3.
unscenario-3:
	@if [ ! -f .scenario-3-applied ]; then \
		echo "Scenario 3 is not currently injected (nothing to reset)."; \
	else \
		kubectl set env deployment/transaction-service -n finance FRAUD_QUEUE_DUPLICATE_FACTOR=1; \
		kubectl rollout restart deployment/transaction-service -n finance; \
		rm -f .scenario-3-applied; \
		echo "✓ Scenario 3 reset."; \
	fi
