# ADR 0003: Gateway API for ingress; init-container migrations with an advisory lock

- **Status:** Accepted
- **Date:** 2026-10-20

## 1. Gateway API (Envoy Gateway) instead of Ingress / ingress-nginx

### Context
The community ingress-nginx controller was retired upstream in March 2026. A
platform built now should not start on an unmaintained edge component.
Gateway API is the Kubernetes successor to Ingress and separates concerns that
Ingress mixes together.

### Decision
- **Envoy Gateway** (pinned) implements Gateway API on AKS.
- The **platform team owns one shared `Gateway`** (`hangar-gateway`) in
  `envoy-gateway-system`. **App teams own `HTTPRoute`s** in their namespaces.
- A namespace can attach routes only if labelled `hangar.io/gateway-access=true`.
  This label is the ingress half of onboarding a new mission team.
- Routes are allow-lists: Sortie Tracker exposes `/api/`, `/healthz`, `/docs`,
  `/openapi.json`. `/metrics` and `/readyz` return 404 at the edge.
- Envoy JSON access logs carry `X-Request-ID`, which Envoy generates if absent
  and the app echoes, so one ID joins gateway and application logs.

### Consequences
- TLS is not yet terminated (needs a DNS name; cert-manager is the follow-up).
- Gateway API CRDs are installed and versioned by the Envoy Gateway chart.

## 2. Database migrations

### Options considered
| Option | Problem |
|--------|---------|
| Helm `pre-upgrade` hook Job | The Job needs the ServiceAccount and SecretProviderClass, which would also have to be hooks. Recreating the ServiceAccount changes its UID and invalidates running pods' projected tokens, breaking workload identity mid-rollout. |
| Manual / CI step | Couples deploys to a separate credentialed runner with DB network access. |
| **Init container + advisory lock** | Chosen. |

### Decision
Each pod runs `alembic upgrade head` in an init container with the same
identity, secrets and network policy as the app. `migrations/env.py` takes a
PostgreSQL **session advisory lock** first, so concurrent pods serialize: one
migrates, the rest see `head` and exit. An integration test proves a second
runner blocks while the lock is held.

### Consequences
- Migrations must be **backward compatible** (expand/contract), because old
  pods keep serving while new ones start. This is the right discipline for
  zero-downtime deploys anyway.
- A failing migration fails the init container. The rollout stalls with old
  pods still serving, and `helm --rollback-on-failure` reverts the release.
