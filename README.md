# Project HANGAR: Mission App Onboarding Platform on Azure

A secure, automated Azure platform that onboards a legacy mission application,
**Sortie Tracker** (a FastAPI service tracking aircraft sorties and maintenance
status), migrates it and its data off a hand-built VM, and operates it on AKS
with full CI/CD, observability, and AI-assisted incident triage.

> Portfolio project demonstrating the ability to *operate and optimize cloud
> platforms, automate infrastructure, and support mission-focused teams*.

## Architecture

```
GitHub Actions ──OIDC (no secrets)──▶ Azure
                                      ├─ rg-hangar-tfstate   remote state (Entra-only, versioned, locked)
                                      └─ rg-hangar-<env>
                                         ├─ VNet
                                         │   ├─ snet-aks     AKS: ingress-nginx, sortie-tracker,
                                         │   │               Key Vault CSI, kube-prometheus-stack
                                         │   ├─ snet-db      Azure Database for PostgreSQL (private)
                                         │   └─ snet-legacy  Legacy Ubuntu VM (Ansible-managed, migration source)
                                         ├─ ACR, Key Vault
                                         └─ Log Analytics, Container Insights, Alerts
```

## Tech stack

| Area                     | Tools                                                        |
|--------------------------|--------------------------------------------------------------|
| Cloud / IaC              | Microsoft Azure, Terraform, Terragrunt                       |
| Containers               | Docker, Azure Kubernetes Service, Helm                       |
| CI/CD                    | GitHub Actions (OIDC, environments, reusable workflows)      |
| Automation               | Python, Bash                                                 |
| Configuration management | Ansible (dynamic Azure inventory, CIS/STIG-style hardening)  |
| Security                 | Checkov, tflint, Trivy, gitleaks, Workload Identity, Key Vault |
| Observability            | Prometheus, Grafana, Azure Monitor, LLM-assisted log triage  |

## Roadmap

| Phase | Scope                                              | Status      |
|-------|----------------------------------------------------|-------------|
| 0     | Repo standards, remote state, GitHub OIDC          | Done        |
| 1     | Terraform modules + Terragrunt environments        | Done        |
| 2     | Sortie Tracker app + Docker                        | Done        |
| 3     | Helm chart + AKS platform add-ons                  | Done        |
| 4     | GitHub Actions CI/CD                               | Done        |
| 5     | Ansible + legacy-to-AKS migration                  | Planned     |
| 6     | Monitoring, chaos drills, runbooks, GenAI triage   | Planned     |
| 7     | Docs, ADRs, demo                                   | Planned     |

## Quick start (Phase 0)

Run from **WSL2 (Ubuntu)**, Linux or macOS.

```bash
make prereqs                       # verify toolchain
az login && az account set -s <subscription-id>
make bootstrap-state               # Terraform state backend
git remote add origin git@github.com:<you>/project-hangar.git
make bootstrap-oidc                # or: SET_GH_VARS=true make bootstrap-oidc
make hooks                         # install pre-commit hooks
```

Bootstrap writes non-secret settings (subscription, state account, client ID) to
`.env.hangar`, which is gitignored and read automatically by `make`. Optional
settings are documented in [.env.hangar.example](.env.hangar.example).

## Infrastructure (Phase 1)

Eight Terragrunt units per environment, applied in dependency order:

```
foundation ─┬─ network ─┬─ aks ──────┬─ app-identity
            ├─ acr ─────┘            │
            ├─ keyvault ─┬───────────┘
            │            └─ postgres (also needs network)
            └─ legacy-vm (needs network)
```

| Unit         | Module              | What it builds                                                         |
|--------------|---------------------|------------------------------------------------------------------------|
| foundation   | `foundation`        | Resource group, Log Analytics workspace, alert action group            |
| network      | `network`           | VNet, aks/db/legacy subnets with NSGs, PostgreSQL private DNS zone     |
| acr          | `acr`               | Private registry (admin user disabled), audit logs                     |
| keyvault     | `keyvault`          | RBAC-mode Key Vault, audit logs                                        |
| aks          | `aks`               | Entra-only AKS, workload identity, Cilium, KV CSI, Container Insights  |
| postgres     | `postgres`          | Private Flexible Server, generated creds stored in Key Vault           |
| app-identity | `workload_identity` | Managed identity federated to the app's Kubernetes service account     |
| legacy-vm    | `legacy_vm`         | Ubuntu VM that Ansible turns into the pre-migration deployment         |

```bash
make infra-validate              # terraform validate + terragrunt hcl validate
make infra-scan                  # Checkov policy scan
make infra-plan                  # ENV=dev by default
make infra-apply                 # ~15-20 min for a fresh environment
make aks-credentials
make infra-destroy               # tear down when finished; dev is designed for this
make infra-plan ENV=prod
make infra-unit UNIT=aks CMD=plan
```

| Setting          | dev                  | prod                              |
|------------------|----------------------|-----------------------------------|
| AKS tier / nodes | Free, 1-3 × B2ms     | Standard (SLA), 2-5 × D2s_v5      |
| PostgreSQL       | B1ms, 7-day backups  | D2ds_v5, zone-redundant HA, 35-day |
| Key Vault        | 7-day soft delete    | 90-day soft delete + purge protection |
| Log retention    | 30 days, 1 GB/day cap| 90 days                           |

## Application (Phase 2)

**Sortie Tracker** is a FastAPI service tracking aircraft mission capability
(FMC / PMC / NMC) and sortie lifecycles, with the business rules a maintenance
operations center would enforce:

- NMC aircraft cannot be scheduled or launched
- An aircraft cannot fly two sorties at once
- Sorties move `SCHEDULED → AIRBORNE → LANDED|ABORTED` or `SCHEDULED → CANCELLED`, nothing else
- A post-flight maintenance write-up grounds the aircraft (NMC)
- `GET /api/v1/readiness` reports the **mission-capable rate**, a core USAF readiness KPI

| Endpoint                               | Purpose                                         |
|----------------------------------------|-------------------------------------------------|
| `GET/POST /api/v1/aircraft`, `GET/PATCH /api/v1/aircraft/{id}` | Fleet management             |
| `GET/POST /api/v1/sorties`, `POST /api/v1/sorties/{id}/transition` | Sortie lifecycle         |
| `GET /api/v1/readiness`                | Fleet readiness summary                         |
| `GET /healthz` / `GET /readyz`         | Liveness (no DB) / readiness (checks DB)        |
| `GET /metrics`                         | Prometheus RED + business metrics               |
| `GET /docs`                            | OpenAPI UI                                      |

**Operability built in:**
- One JSON log line per event, each carrying the request's `X-Request-ID`
  (generated or propagated), returned on every response including errors
- Business-rule rejections return a stable `rule` name, are logged, and counted
  in `sortie_tracker_business_rule_violations_total{rule=...}`
- DB outages return 503 (not 500) and fail `/readyz` without failing `/healthz`,
  so Kubernetes drains traffic instead of restart-looping pods
- Configuration from env vars **or** Key Vault CSI-mounted files, using the same
  secret names Terraform writes

**Container:** multi-stage, Python 3.13 slim, OS patches applied, pip removed,
UID 10001, read-only root filesystem compatible, dependencies pinned in
`app/constraints.txt`. 0 fixable HIGH/CRITICAL vulnerabilities (Trivy) and
Checkov clean at time of writing.

```bash
make app-venv                    # local virtualenv
make app-lint app-test           # ruff + unit tests (SQLite, no Docker)
make app-test-integration        # migrations, schema drift, API on PostgreSQL 16
make app-up app-seed             # stack on http://localhost:18080 with 24 aircraft / 300 sorties
make app-build app-scan          # image tagged with git SHA + Trivy gate
make app-down
```

## Kubernetes (Phase 3)

```
Internet ─▶ Azure LB ─▶ Envoy Gateway (hangar-gateway) ─HTTPRoute─▶ sortie-tracker Service ─▶ pods
                         envoy-gateway-system                         sortie-tracker ns (PSS: restricted)
                                                                       │  init: alembic upgrade head (advisory lock)
                                                                       │  CSI: Key Vault secrets via workload identity
                                                                       └─▶ PostgreSQL subnet :5432 (NetworkPolicy)
Prometheus (monitoring ns) ─ServiceMonitor─▶ /metrics (cluster-internal only)
```

**Platform layer** (`deploy/platform/`, owned by the platform team):
- Namespaces with Pod Security Admission: app namespaces enforce `restricted`
- Envoy Gateway with one shared `Gateway`; namespaces opt in with
  `hangar.io/gateway-access=true`. Gateway API replaces the retired ingress-nginx.
- kube-prometheus-stack: discovers ServiceMonitors in every namespace; the Grafana
  password is generated into a Secret, never committed

**Application chart** (`deploy/helm/sortie-tracker/`, owned by the app team):
- Workload identity ServiceAccount + Key Vault `SecretProviderClass`: no secrets in the cluster
- Migrations in an init container, serialized by a PostgreSQL advisory lock
- Non-root, read-only root FS, all capabilities dropped, seccomp `RuntimeDefault`,
  no service-account token mounted
- Startup/liveness/readiness probes, `preStop` drain, zero-downtime rolling update
- HPA (fast scale-up, slow scale-down), PodDisruptionBudget, zone/host spreading
- Default-deny NetworkPolicy: in from gateway + Prometheus; out to DNS + PostgreSQL only
- HTTPRoute allow-list keeps `/metrics` and `/readyz` off the internet

```bash
make chart-lint                  # helm lint + kubeconform (with CRD schemas) + Checkov
make k8s-local-e2e               # full platform + chart on kind: PSS, NetworkPolicy, gateway, migrations
make aks-credentials ENV=dev
make platform-install            # namespaces, Envoy Gateway, Prometheus/Grafana
make acr-push deploy ENV=dev     # push image, helm upgrade, smoke test through the gateway
```

## CI/CD (Phase 4)

```
PR      ─▶ quality · app (test, build, Trivy, SBOM) · infra (validate, Checkov, plan → PR comment) · k8s (lint, kind e2e)
main    ─▶ app:   push dev ACR ─▶ deploy dev ─▶ [approval] ─▶ import same digest to prod ACR ─▶ deploy prod
           infra: apply dev ─▶ [approval] ─▶ apply prod
```

- **Passwordless:** GitHub OIDC → Entra ID. Plans run as the PR identity;
  applies and deploys run as a GitHub Environment (prod requires approval).
- **Build once, promote by digest:** prod runs the exact bytes that were scanned and tested in dev.
- **Supply chain:** actions pinned to commit SHAs, tool binaries verified
  against committed SHA-256s, service images pinned by digest, Dependabot with
  a 14-day cooldown, CycloneDX SBOM per image, SARIF to GitHub code scanning.
- **Safe deploys:** Helm `--rollback-on-failure`, smoke test through the
  gateway (including "`/metrics` must 404"), automatic rollback if smoke fails.

**One-time GitHub setup:**
1. `SET_GH_VARS=true make bootstrap-oidc` sets the Azure/state repository variables.
2. Add the repository variables `HANGAR_SSH_PUBLIC_KEY` (legacy VM) and, optionally,
   `HANGAR_ALLOWED_SSH_CIDRS` and `HANGAR_ALERT_EMAILS`.
3. Settings → Environments → `prod` → add required reviewers.
4. Make `main` the default branch and protect it, requiring the `quality`, `app`, `infra` and `k8s` checks.

```bash
make ci-lint                     # actionlint + zizmor on the workflows
```

## Repository layout

```
bootstrap/   one-time Azure setup (state backend, OIDC identity)
infra/       Terraform modules + Terragrunt environments        (Phase 1)
app/         Sortie Tracker FastAPI service                     (Phase 2)
deploy/      Helm chart + cluster add-ons                       (Phase 3)
.github/     CI/CD workflows                                    (Phase 4)
ansible/     roles and playbooks                                (Phase 5)
scripts/     migration, cutover, chaos, log analysis tooling
docs/        architecture, ADRs, runbooks, onboarding guide
```

## Design decisions

- [ADR 0001: GitHub Actions authenticates to Azure with OIDC federation](docs/adr/0001-github-oidc-federation.md)
- [ADR 0002: Terragrunt units per component, one state file per unit](docs/adr/0002-terragrunt-unit-layout.md)
- [ADR 0003: Gateway API for ingress; init-container migrations with an advisory lock](docs/adr/0003-gateway-api-and-migrations.md)
- [ADR 0004: CI/CD on GitHub Actions: build once, promote by digest, gate prod](docs/adr/0004-ci-cd-pipeline.md)
