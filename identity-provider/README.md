# identity-provider — Keycloak (Open-Source IdP)

[Keycloak](https://www.keycloak.org/) is an open-source Identity and Access Management (IAM) solution backed by Red Hat and the CNCF ecosystem. It provides SAML 2.0 and OIDC support out of the box and mirrors the enterprise IdPs common in banking and insurance (Okta, Azure AD, PingFederate, IBM Security Verify).

This service adds:

- A pre-configured **`finance` realm** with five roles (`finance-analyst`, `finance-trader`, `finance-admin`, `finance-auditor`, `finance-compliance`) and five sample users
- An **OIDC client** (`finance-gateway`) so `gateway-api` can validate Bearer tokens and inject user identity into logs

---

## Quick Start

Keycloak starts automatically when you deploy the full stack:

```bash
make deploy-k8s
```

| Endpoint | URL | Credentials |
|---|---|---|
| **Admin console (primary)** | `https://localhost:30443/admin/master/console/#/finance` | `admin` / `Finance@Admin2025!` (dev default — `keycloak-admin-password` key in the `app-secrets` K8s Secret, not an `.env` var) |
| **Realm account page** | `https://localhost:30443/realms/finance/account/` | any finance realm user |

The primary URLs above go through the **nginx HTTPS proxy** (self-signed certificate, accept the browser warning
once) on NodePort `30443` — no extra setup required after `make deploy-k8s`. This matches the canonical access URL
documented in the root [`README.md`](../README.md#identity-provider).

The `localhost:8089` endpoints below are **not** exposed automatically — they require a manual port-forward, and
are intended for local `curl`/token-testing workflows (see [OIDC Integration with gateway-api](#oidc-integration-with-gateway-api)),
not for primary browser access:

```bash
kubectl port-forward svc/keycloak 8089:8080 -n finance
```

| Endpoint (after port-forward) | URL | Credentials |
|---|---|---|
| Admin console | http://localhost:8089 | `admin` / `Finance@Admin2025!` (dev default — `keycloak-admin-password` key in the `app-secrets` K8s Secret) |
| Finance realm | http://localhost:8089/realms/finance | — |
| OIDC discovery | http://localhost:8089/realms/finance/.well-known/openid-configuration | — |
| SAML IdP metadata | http://localhost:8089/realms/finance/protocol/saml/descriptor | — |

The `finance` realm is imported automatically from `realm-export/finance-realm.json` on first start.

---

## Finance Realm

### Roles

| Role | Description |
|---|---|
| `finance-analyst` | Read-only: view accounts, balances, transaction history |
| `finance-trader` | Initiate payments and transfers; view own history |
| `finance-admin` | Full access: manage accounts, approve high-value transactions |
| `finance-auditor` | Compliance / read-only: full history for audit trail |
| `finance-compliance` | View accounts · approve or reject pending payments |

### Sample Users

| Username | Email | Role | Password |
|---|---|---|---|
| `alice.analyst` | alice.analyst@finance.local | `finance-analyst` | `Finance@2025!` |
| `bob.trader` | bob.trader@finance.local | `finance-trader` | `Finance@2025!` |
| `carol.admin` | carol.admin@finance.local | `finance-admin` | `Finance@2025!` |
| `dave.auditor` | dave.auditor@finance.local | `finance-auditor` | `Finance@2025!` |
| `eve.compliance` | eve.compliance@finance.local | `finance-compliance` | `Finance@2025!` |

> **Security note:** These passwords are for local development only. In any non-local environment, replace them via the Keycloak admin console or the `kcadm.sh` CLI before deployment.

---

## OIDC Integration with gateway-api

The `finance-gateway` OIDC client allows `gateway-api` to validate Bearer tokens issued by Keycloak. This integration is **active by default** — the `verify_token` FastAPI dependency is already wired into all protected routes.

### Obtaining a token for testing

Requires `kubectl port-forward svc/keycloak 8089:8080 -n finance` first — see [Quick Start](#quick-start).

```bash
# Exchange username + password for an access token (Resource Owner Password grant)
TOKEN=$(curl -s -X POST \
  "http://localhost:8089/realms/finance/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=finance-gateway" \
  -d "client_secret=REPLACE_WITH_SECRET" \
  -d "username=bob.trader" \
  -d "password=Finance@2025!" \
  | jq -r .access_token)

# Call the gateway API with the Bearer token
curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/v1/accounts/acc-001/balance
```

### What the OIDC integration provides

1. Every request to a protected route is validated against Keycloak's JWKS endpoint
2. The authenticated user's `sub` (UUID) and `roles` are extracted from the JWT
3. `user.id` and `user.roles` appear in every **structured log record** — enabling log-based user-activity analysis out of the box
4. Unauthenticated requests receive a `401 Unauthorized` before reaching business logic

---

## Security Notes

- **OIDC secrets:** The `finance-gateway` client secret is `REPLACE_WITH_SECRET` in the realm export. Rotate this before any non-local deployment via the Keycloak admin console and update `KEYCLOAK_CLIENT_SECRET` in your `.env` / secrets manager.
- **User passwords:** The sample user passwords in `finance-realm.json` are for local development only. Do not import this realm directly into a production Keycloak instance.
- **Network access:** Primary access already goes through the nginx HTTPS proxy (`https://localhost:30443`, self-signed cert). Only expose Keycloak beyond that over HTTPS as well — in Kubernetes, use an Ingress with TLS termination; in Terraform (AWS), use a load balancer with an ACM-managed certificate. The `localhost:8089` port-forward is for local `curl`/token-testing only and should never be exposed externally.
- **PII in logs:** When the OIDC middleware is enabled, `user.email` appears in structured log records. If this constitutes PII under your data-handling policy, use `user.sub` (the opaque UUID subject) instead, and resolve the email only in your identity service.

---

## Key References

| Topic | URL |
|---|---|
| Keycloak OIDC guide | https://www.keycloak.org/docs/latest/server_admin/#_oidc_clients |
| Keycloak Docker | https://www.keycloak.org/server/containers |
