# Finance Sample App
#
# DD_VERSION is auto-set to the git short SHA and embedded in image tags.
# This ties every container image to an exact commit for traceability.
#
# Run 'make help' for the full list of targets with one-line descriptions.
# The end-to-end workflows below show the recommended target ordering.
#
# AWS + K8s workflow:
#   aws sso login --profile <profile>   # authenticate
#   make tf-plan-aws                    # review the plan first
#   make tf-apply-aws                   # provision EKS, ECR, VPC, IAM (~15-20 min)
#   make tf-configure-kubectl           # configure kubectl
#   make build-ecr                      # build & push images for linux/amd64
#   make deploy-k8s-eks                 # deploy app (includes gp3 StorageClass)

.PHONY: all build build-ecr version test test-traffic deploy-k8s deploy-k8s-eks undeploy-k8s teardown tf-plan-aws tf-apply-aws tf-configure-kubectl frontend-url tf-destroy-aws help

# Resolve DD_VERSION once so all targets share the same value.
# Falls back to 'dev' when git is not available (e.g. in a bare CI image).
DD_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo 'dev')

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
define create_realm_cm
	kubectl create configmap keycloak-realm-import \
		--from-file=identity-provider/realm-export/ \
		-n finance --dry-run=client -o yaml | kubectl apply -f -
endef

# Create the traffic-generator-script ConfigMap.
define create_traffic_cm
	kubectl create configmap traffic-generator-script \
		--from-file=generate-traffic.py=scripts/generate-traffic.py \
		-n finance --dry-run=client -o yaml | kubectl apply -f -
endef

# Build the frontend-dashboard ConfigMap, injecting KEYCLOAK_PUBLIC_URL.
define create_frontend_cm
	KEYCLOAK_URL=$$(grep 'KEYCLOAK_PUBLIC_URL' deploy/kubernetes/base/01-config.yaml | sed 's/.*: *"\(.*\)"/\1/'); \
	sed "s|https://localhost:30443|$$KEYCLOAK_URL|g" frontend-stub/index.html > /tmp/finance-index.html; \
	kubectl create configmap frontend-dashboard \
		--from-file=index.html=/tmp/finance-index.html \
		-n finance --dry-run=client -o yaml | kubectl apply -f -; \
	rm -f /tmp/finance-index.html
endef
# ──────────────────────────────────────────────────────────────────────


all: build

## help: Show this help message (all available make targets with descriptions).
help:
	@echo "Finance Sample App"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@awk '/^## [a-zA-Z0-9_-]+:/ { \
			sub(/^## /, ""); \
			split($$0, a, ":"); \
			target=a[1]; \
			sub(/^[^:]*: */, ""); \
			desc=$$0; \
			printf "  \033[36m%-30s\033[0m %s\n", target, desc \
		}' $(MAKEFILE_LIST)
	@echo ""

## version: Print the DD_VERSION that will be embedded in image tags.
version:
	@echo "DD_VERSION=$(DD_VERSION)"

## build: Build all service images for the local platform.
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
		             ./$$svc; \
	done
	@echo ""
	@echo "✓ All images built. To deploy to local k3s:"
	@echo "  # Docker Desktop/Rancher Desktop: images available immediately — no load step needed."
	@echo "  # kind:     kind load docker-image finance-sample-app-<svc>:latest"
	@echo "  # k3d:      k3d image import finance-sample-app-<svc>:latest"
	@echo "  # minikube: minikube image load finance-sample-app-<svc>:latest"
	@echo "  kubectl rollout restart deployment -n finance"

## build-ecr: Build all service images for linux/amd64 and push directly to ECR.
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

## test: Run the e2e test suite against the running stack.
##       Prerequisites: make deploy-k8s (uses Python stdlib only — no pip install required).
##       Note: requires kubectl port-forward or NodePort access to the services.
##       For a no-setup check, watch the in-cluster traffic generator instead:
##         kubectl logs -n finance deploy/traffic-generator -f
test:
	python3 scripts/test-e2e.py

## test-traffic: Run the traffic generator locally for a fixed duration.
##               The in-cluster traffic-generator Deployment already runs continuously.
##               Use this to temporarily boost traffic or test from your laptop.
##               Note: requires services reachable on localhost (kubectl port-forward).
test-traffic:
	python3 scripts/generate-traffic.py --rate 2 --duration 60



## deploy-k8s: Deploy the Finance app to Kubernetes.
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

## deploy-k8s-eks: Deploy to EKS using Kustomize overlay.
##                 Patches base manifests with ECR image URLs, gp3 StorageClass,
##                 and imagePullPolicy:Always. Safe to re-run (idempotent).
##                 Prerequisites: make tf-apply-aws, make tf-configure-kubectl, make build-ecr.
deploy-k8s-eks:
	bash scripts/generate-eks-kustomization.sh
	@echo "Creating finance namespace (idempotent)..."
	kubectl apply -f deploy/kubernetes/base/00-namespace.yaml
	@echo "Creating Keycloak realm ConfigMap..."
	@$(create_realm_cm)
	@echo "Applying config and secrets..."
	kubectl apply -f deploy/kubernetes/base/01-config.yaml
	kubectl apply -f deploy/kubernetes/base/02-secrets.yaml
	@echo "Creating traffic-generator script ConfigMap..."
	@$(create_traffic_cm)
	@echo "Creating TLS secret for nginx Keycloak HTTPS proxy (idempotent)..."
	@$(ensure_keycloak_tls)
	@echo "Creating frontend dashboard ConfigMap (injecting current KEYCLOAK_PUBLIC_URL)..."
	@$(create_frontend_cm)
	@echo "Applying EKS overlay (ECR images + gp3 StorageClass + infrastructure + services)..."
	kubectl apply -k deploy/kubernetes/overlays/eks
	@echo "Waiting for PostgreSQL to be ready..."
	kubectl rollout status statefulset/postgres-ledger -n finance --timeout=120s
	@echo ""
	@echo "✓  Deployed. Check pod status:"
	@echo "     kubectl get pods -n finance"
	@echo ""
	@echo "⚠  Keycloak public URL: the frontend Service (nginx) sits behind the"
	@echo "   Terraform-managed NLB and proxies Keycloak — the keycloak Service"
	@echo "   itself is ClusterIP-only. The NLB hostname is already known (it was"
	@echo "   created by 'make tf-apply-aws', not by this Service), so run:"
	@echo "   (use frontend_keycloak_https_url — the HTTPS :8443 listener — NOT frontend_url;"
	@echo "    patching KEYCLOAK_PUBLIC_URL to the plain :80 URL causes login HTTP 405.)"
	@echo "     FE_KC_URL=\$$(cd deploy/terraform/aws && terraform output -raw frontend_keycloak_https_url)"
	@echo "     kubectl patch configmap app-config -n finance --type=merge -p \"{\\\"data\\\":{\\\"KEYCLOAK_PUBLIC_URL\\\":\\\"\$$FE_KC_URL\\\"}}\""
	@echo "     sed \"s|https://localhost:30443|\$$FE_KC_URL|g\" frontend-stub/index.html > /tmp/finance-index.html"
	@echo "     kubectl create configmap frontend-dashboard --from-file=index.html=/tmp/finance-index.html -n finance --dry-run=client -o yaml | kubectl apply -f -"
	@echo "     kubectl rollout restart deployment/keycloak deployment/frontend -n finance"

## undeploy-k8s: Remove all Finance app resources from Kubernetes (namespaces only).
##               Does NOT delete persistent data — use 'make teardown' for a full reset.
undeploy-k8s:
	kubectl delete namespace finance --ignore-not-found
	# gp3 is cluster-scoped (not namespaced) — must be deleted separately
	kubectl delete storageclass gp3 --ignore-not-found

## teardown: Full reset — removes all K8s resources AND cleans up persistent data.
##           Deletes:
##             - finance namespace (all app pods, services, configmaps)
##             - Any leftover Docker volumes (postgres, redis, artemis, keycloak)
##             - Port-forward processes
##           Safe to run even if some resources are already gone.
##
##           After teardown, start fresh with:
##             make build && make deploy-k8s
teardown:
	@echo "==> Killing any stray kubectl port-forward processes..."
	@pkill -f 'kubectl port-forward' 2>/dev/null || true
	@echo "==> Deleting finance namespace (app pods, PVCs, services)..."
	@kubectl delete namespace finance --ignore-not-found 2>&1
	@echo "==> Removing leftover Docker volumes..."
	@for vol in postgres-data redis-data artemis-data keycloak-data; do \
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

## tf-plan-aws: Initialise and plan the Terraform AWS (EKS) target.
##              Uses the AWS_PROFILE env var. Override vars: TF_AWS_VARS="-var-file=staging.tfvars -var aws_profile=<name>"
TF_AWS_VARS ?= -var-file=staging.tfvars
tf-plan-aws: deploy/terraform/aws/staging.tfvars
	cd deploy/terraform/aws && terraform init && terraform plan $(TF_AWS_VARS)

## tf-apply-aws: Apply the Terraform AWS plan (creates EKS, ECR, VPC, IAM).
##               WARNING: this provisions real AWS resources and incurs cost.
tf-apply-aws: deploy/terraform/aws/staging.tfvars
	bash scripts/aws-pre-apply.sh
	cd deploy/terraform/aws && terraform init && terraform apply $(TF_AWS_VARS)

## tf-configure-kubectl: Update kubeconfig to point kubectl at the EKS cluster.
##                       Run after tf-apply-aws before deploy-k8s.
tf-configure-kubectl:
	eval "$$(cd deploy/terraform/aws && terraform output -raw kubeconfig_command)"

## frontend-url: Print the public URL of the Finance app frontend on EKS.
##               Available as soon as make tf-apply-aws completes (Terraform-managed
##               NLB, not a Kubernetes LoadBalancer Service) — no need to deploy the
##               app first.
frontend-url:
	@cd deploy/terraform/aws && terraform output -raw frontend_url 2>/dev/null && echo "" \
		|| echo "No NLB yet — run 'make tf-apply-aws' first."

## tf-destroy-aws: Safely destroy all AWS resources created by Terraform.
##                 Automatically handles the dependency ordering that plain
##                 'terraform destroy' gets wrong:
##                   1. Deletes K8s LoadBalancer services (releases the AWS ELB
##                      so the VPC can be deleted — skipped if kubectl unreachable)
##                   2. Deletes EKS node groups + add-ons via AWS CLI before the
##                      cluster (avoids ResourceInUseException)
##                   3. Force-deletes Secrets Manager secrets immediately
##                      (avoids 'scheduled for deletion' errors on re-apply)
##                   4. Runs terraform destroy for remaining resources (VPC, IAM)
tf-destroy-aws:
	bash scripts/aws-force-destroy.sh --yes
