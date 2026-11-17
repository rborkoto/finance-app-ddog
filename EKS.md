# Running on AWS EKS (optional)

Use this instead of a local cluster if you want public URLs, for example to run Datadog synthetic tests from public locations. It costs money while it runs, so tear it down when you finish.

Terraform in `deploy/terraform/aws/` creates the EKS cluster, VPC, ECR repositories, IAM roles, a Network Load Balancer for the frontend, and a CloudWatch log group. As with the local path, it installs nothing Datadog. It does create a few things you can choose to use:
- **Secrets Manager entries:** empty `dd-api-key`, `dd-app-key` and `datadog-dbm-password` entries you can populate.
- **IAM role:** `datadog_integration`, a read-only role for the Datadog AWS integration (see the `dd_integration_role_arn` output).
- **Firewall rule:** a node security group rule for port 8000, which the Datadog Cluster Agent's admission controller needs on EKS.

## Prerequisites

AWS CLI 2.x with an SSO profile (`aws configure sso`), `terraform` 1.5 or later, plus the tools in the root README.

## 1. Configure

```bash
aws sso login --profile <profile>
cp deploy/terraform/aws/staging.tfvars.example deploy/terraform/aws/staging.tfvars
# edit: aws_profile, aws_region, cluster_name
```

Decide now how Keycloak gets its certificate, because changing it later needs a re-apply:

| Option | `staging.tfvars` | Result |
|---|---|---|
| A, self-signed (default) | leave `domain_name` and `route53_zone_id` empty | Keycloak on `:8443` with a self-signed certificate. Accept the browser warning once. |
| B, your domain in Route 53 in this account | set `domain_name` and `route53_zone_id` | Keycloak on `:9443` with a trusted ACM certificate, fully automated |
| C, your domain managed elsewhere | set `domain_name` only | Keycloak on `:9443` with a trusted ACM certificate, after you add DNS records (step 3) |

## 2. Provision (about 15 to 20 minutes)

```bash
make tf-plan-aws
make tf-apply-aws
make tf-configure-kubectl && kubectl get nodes
```

## 3. Certificate DNS (option C only)

1. `make tf-apply-aws` requests the certificate, which stays pending validation.
2. Get the validation records and add each as a CNAME at your DNS provider:
   ```bash
   cd deploy/terraform/aws && terraform output -json acm_validation_records
   ```
3. Point `domain_name` at the load balancer: `terraform output -raw frontend_lb_dns_name`.
4. Run `make tf-apply-aws` again. It waits for validation. If it times out while DNS propagates, run it again.

## 4. Deploy the app

Export Keycloak's public URL and the dashboard URL first, so login works on the first deploy.

Option A:
```bash
export FE_URL=$(cd deploy/terraform/aws && terraform output -raw frontend_keycloak_https_url)
export DASH_URL=$(cd deploy/terraform/aws && terraform output -raw frontend_url)
```

Option B or C:
```bash
export FE_URL=$(cd deploy/terraform/aws && terraform output -raw frontend_keycloak_acm_url)
export DASH_URL=$(cd deploy/terraform/aws && terraform output -raw frontend_url)
```

Then build, push and deploy:
```bash
eval "$(cd deploy/terraform/aws && terraform output -raw ecr_login_command)"
make build-ecr
make deploy-k8s-eks
```

The dashboard is at `terraform output -raw frontend_url`.

## Differences from the local path

- **Applying manifest changes:** run `make build-ecr && make deploy-k8s-eks` wherever the exercise says `make build` or `make deploy-k8s`.
- **RUM snippet changes:** `make deploy-k8s-eks` also rebuilds the frontend ConfigMap with the right Keycloak URL. Run it after editing `frontend-stub/index.html`, then restart `frontend`.
- **Kubelet TLS:** the local-cluster kubelet TLS workaround from the Task 1 hints is not needed on EKS. Leave verification on.

## If you forgot to export FE_URL and DASH_URL

Dashboard login fails with a `NetworkError`. Export them as in step 4, run `make deploy-k8s-eks` again, then restart Keycloak and the frontend so they pick up the new values:

```bash
kubectl rollout restart deployment/keycloak deployment/frontend -n finance
```

Keycloak runs in dev mode with an in-memory database, so any Keycloak restart re-imports the realm from the ConfigMap that `make deploy-k8s-eks` generates.

## Tear down

```bash
make tf-destroy-aws
```

This deletes the cluster and everything Terraform created, in the right order. Remove anything you created in Datadog separately.
