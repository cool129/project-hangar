# Architecture

Project HANGAR is a platform for onboarding mission applications onto Azure. It is
shown end to end with one application, **Sortie Tracker**, moved from a hand-built
VM onto AKS. This document is the engineering view; the [README](../README.md) is
the summary.

- [1. System overview](#1-system-overview)
- [2. Request path and trust boundaries](#2-request-path-and-trust-boundaries)
- [3. Infrastructure as code](#3-infrastructure-as-code)
- [4. Delivery pipeline](#4-delivery-pipeline)
- [5. Legacy migration](#5-legacy-migration)
- [6. Observability and incident response](#6-observability-and-incident-response)
- [7. Security controls](#7-security-controls)
- [8. Design decisions](#8-design-decisions)

## 1. System overview

```mermaid
flowchart TB
  users([Mission users])
  dev([Engineer]) -->|pull request| gh[GitHub Actions]

  subgraph azure[Azure subscription]
    subgraph env["Environment (dev, prod)"]
      subgraph vnet[VNet]
        subgraph aks[AKS cluster]
          gw[Envoy Gateway] --> app[Sortie Tracker pods]
          prom[Prometheus + Grafana]
        end
        pg[(PostgreSQL<br/>private subnet)]
        vm[Legacy VM<br/>Ansible-managed]
      end
      acr[(Container<br/>Registry)]
      kv[(Key Vault)]
      law[(Log Analytics)]
    end
    tfstate[(Terraform state)]
  end

  users --> gw
  app --> pg
  app -.->|workload identity| kv
  vm -.->|data migration| pg
  vm -.->|cutover proxy| gw
  aks -.->|logs| law
  gh ==>|OIDC, no secrets| tfstate
  gh ==>|image by digest| acr
  gh ==>|helm deploy| aks
```

| Layer | Owner | Lives in |
|-------|-------|----------|
| Cloud foundation: network, registry, vault, database, cluster, alerts | Platform team | `infra/` (Terraform + Terragrunt) |
| Cluster platform: namespaces, gateway, monitoring | Platform team | `deploy/platform/` |
| Application: chart, SLOs, dashboard | App team | `app/`, `deploy/helm/sortie-tracker/` |
| Legacy host and migration | Platform + app team | `ansible/`, `scripts/migrate_db.py`, `scripts/cutover.sh` |

## 2. Request path and trust boundaries

```mermaid
flowchart LR
  client([Client]) -->|HTTP :80| lb[Azure LB]
  lb --> envoy[Envoy proxy<br/>envoy-gateway-system]
  envoy -->|HTTPRoute allow-list:<br/>/api/ /healthz /docs| svc[Service]
  svc --> pod

  subgraph ns[namespace sortie-tracker: PSS restricted, default-deny NetworkPolicy]
    pod[api container<br/>non-root, read-only FS<br/>no SA token]
    init[init: alembic upgrade head<br/>advisory lock]
    csi[/Key Vault CSI mount<br/>/mnt/secrets-store/]
  end

  pod -->|5432 only| pg[(PostgreSQL<br/>private subnet)]
  csi -. workload identity token .-> kv[(Key Vault)]
  prom[Prometheus<br/>monitoring ns] -->|/metrics<br/>cluster-internal| pod
```

- **Edge:** only the routes in the HTTPRoute allow-list are reachable. `/metrics` and `/readyz`
  return 404 from the internet (checked by every deploy's smoke test). Envoy preserves the
  caller's `X-Request-ID` or generates one, and the app logs it on every line.
- **Pod:** the `restricted` Pod Security profile is enforced. The pod runs as a non-root UID with a
  read-only root filesystem, all capabilities dropped, seccomp `RuntimeDefault`, and no
  Kubernetes API token mounted.
- **Identity:** the pod's service account is federated to a managed identity
  (`system:serviceaccount:sortie-tracker:sortie-tracker`), which may read secrets from one
  Key Vault. No credentials exist in the cluster, the image, Helm values or CI.
- **Network:** ingress comes only from the gateway and Prometheus namespaces; egress goes only to
  DNS and the PostgreSQL subnet. The internet is unreachable (verified by the kind e2e test).
- **Failure behaviour:** liveness never checks the database; readiness does. A DB outage drains
  traffic instead of restart-looping pods, and fails fast: the DB connect timeout (2 s) is below
  the probe timeout (3 s) ([postmortem 001](drills/postmortem-001-db-outage.md)).

## 3. Infrastructure as code

Nine Terragrunt units per environment, one state file each, wired by explicit
dependencies ([ADR 0002](adr/0002-terragrunt-unit-layout.md)):

```mermaid
flowchart LR
  foundation --> network & acr & keyvault
  network --> aks
  acr --> aks
  network & keyvault --> postgres
  network --> legacyvm[legacy-vm]
  aks & keyvault --> appid[app-identity]
  aks & postgres --> alerts
```

| Unit | Builds |
|------|--------|
| foundation | Resource group, Log Analytics, alert action group |
| network | VNet; `aks`/`db`/`legacy` subnets with NSGs (db and legacy deny by default); PostgreSQL private DNS |
| acr | Private registry, admin user disabled, audit logs |
| keyvault | RBAC-mode vault, audit logs; purge protection in prod |
| aks | Entra-only auth (local accounts off), workload identity, Azure CNI Overlay + Cilium, KV CSI, Container Insights, audit logs, auto-patching |
| postgres | Flexible Server with VNet integration only; generated admin password written straight to Key Vault; connection auditing; zone-redundant HA in prod |
| app-identity | Managed identity + federated credential for the app's service account |
| legacy-vm | Ubuntu 24.04 VM (SSH keys only), tagged for Ansible's dynamic inventory |
| alerts | Azure Monitor alerts for the PaaS layer + a KQL app-error safety net |

Environment differences live in a single file per environment (`infra/live/<env>/env.hcl`): SKUs,
node counts, retention, HA. Every Checkov exception is justified inline; the accepted
trade-offs (public endpoints guarded by Entra ID, because CI uses GitHub-hosted runners)
are recorded in ADR 0002.

## 4. Delivery pipeline

```mermaid
flowchart LR
  pr([Pull request]) --> q[quality<br/>pre-commit, actionlint, zizmor,<br/>ops-script tests]
  pr --> a[app<br/>ruff, unit + PG integration,<br/>build, Trivy, SBOM]
  pr --> i[infra<br/>fmt, validate, tflint, Checkov,<br/>plan dev+prod → PR comment]
  pr --> k[k8s<br/>helm lint, kubeconform, promtool,<br/>kind end-to-end]
  pr --> an[ansible<br/>ansible-lint, migration rehearsal]

  main([merge to main]) --> push[push image to dev ACR<br/>by digest]
  push --> ddev[deploy dev<br/>+ smoke test]
  ddev --> gate{prod approval}
  gate --> promote[az acr import<br/>same digest → prod ACR]
  promote --> dprod[deploy prod<br/>+ smoke test, auto-rollback]
  main --> adev[terragrunt apply dev] --> gate2{prod approval} --> aprod[terragrunt apply prod]
```

- **No stored cloud secrets:** GitHub OIDC tokens are exchanged for Entra ID tokens. Plans
  authenticate as the pull request; applies and deploys as a GitHub Environment, so only an
  approved prod job can get a prod-capable token ([ADR 0001](adr/0001-github-oidc-federation.md)).
- **Build once, promote by digest:** prod runs the exact image that passed dev
  ([ADR 0004](adr/0004-ci-cd-pipeline.md)).
- **Supply chain:** actions pinned to commit SHAs, CLI tools verified against SHA-256 values
  committed in `scripts/ci/tool-versions.env`, service images pinned by digest, a CycloneDX SBOM
  per image, and Dependabot with a 14-day cooldown.

## 5. Legacy migration

```mermaid
sequenceDiagram
  autonumber
  actor Op as Operator
  participant KV as Key Vault
  participant AKS as AKS app
  participant VM as Legacy VM
  participant PG as Azure PostgreSQL

  Op->>KV: read target DB credentials (env only)
  Op->>AKS: scale to 0 (quiesce target)
  Op->>VM: ansible migrate.yml
  VM->>VM: stop legacy service (freeze writes)
  VM->>PG: preflight: version, Alembic revision, target empty
  VM->>PG: pg_restore --single-transaction (data only)
  VM->>PG: reset sequences, then checksum every table
  alt any failure
    VM->>VM: restart legacy service (rescue)
  end
  VM-->>Op: report.json / report.md (PASS)
  Op->>AKS: scale back, verify migrated row counts
  Op->>VM: ansible cutover.yml: nginx proxies :8000 to gateway
  Note over AKS,PG: Clients keep the legacy URL (strangler pattern)
```

The whole sequence is rehearsed on every PR in Docker (systemd VM over real SSH, Postgres,
the app image). The rehearsal checks idempotence (`changed=0`), refusal on a populated
target, detection of a single tampered row, cutover and rollback.
Procedure: [runbooks/migration.md](runbooks/migration.md).

## 6. Observability and incident response

```mermaid
flowchart LR
  app[pods: JSON logs<br/>+ /metrics] --> prom[Prometheus<br/>SLO recording rules]
  prom --> alerts[burn-rate + cause alerts<br/>promtool unit-tested]
  app --> ci[Container Insights] --> law[(Log Analytics)]
  law --> kql[KQL safety-net alert]
  alerts & kql --> ag[Action group] --> oncall([On-call])
  oncall --> analyzer[log_analyzer.py<br/>findings + runbook links]
  analyzer -->|--ai, redacted aggregates| claude[Claude triage agent<br/>read-only tools, 6-round cap]
  claude --> draft[Incident draft<br/>labelled: verify]
  oncall --> runbook[Runbook] --> fix[Mitigate]
```

- **SLOs** ([slo.md](slo.md)): 99% availability over 30 days, p95 under 500 ms. Multi-window,
  multi-burn-rate alerts page on fast burn and ticket on slow burn.
- **Chaos drills** (`scripts/chaos.sh`) rehearse each alert's failure mode. Drill 001 found six
  issues; four were fixed and re-verified the same day ([postmortem](drills/postmortem-001-db-outage.md)).
- **GenAI triage** is opt-in and bounded ([ADR 0005](adr/0005-genai-incident-triage.md)): the
  deterministic analyzer is the source of truth, and the model drafts the write-up.

## 7. Security controls

| Area | Control | Where |
|------|---------|-------|
| Identity | No stored cloud credentials: OIDC for CI, workload identity for pods, managed identity for kubelet→ACR | `bootstrap/setup-oidc.sh`, `infra/modules/aks`, `workload_identity` |
| Least privilege | CI may assign only 7 named roles (ABAC-conditioned RBAC Administrator), never Owner | ADR 0001 |
| Secrets | Generated by Terraform into Key Vault; mounted by CSI; never in git, images, values or logs | `infra/modules/postgres`, chart `secretproviderclass.yaml` |
| Data plane | Private DB (no public endpoint), TLS enforced, Entra-only state storage, shared keys disabled | `postgres`, `bootstrap-tfstate.sh` |
| Network | Segmented subnets with NSGs; default-deny NetworkPolicy; HTTPRoute allow-list | `network`, chart |
| Workload | PSS `restricted`; non-root; read-only FS; no capabilities; no pip in the image | chart, `app/Dockerfile` |
| Hosts | CIS-style baseline, SSH with FIPS-approved algorithms, auditd, ufw, consent banner | `ansible/roles/baseline_hardening` |
| Supply chain | SHA-pinned actions, checksum-verified tools, Trivy gate, SBOM, Dependabot | `.github/`, `scripts/ci/` |
| Policy as code | Checkov (Terraform, Kubernetes, Dockerfile, Actions), tflint, ansible-lint, zizmor, gitleaks | CI |
| Audit | Key Vault, ACR, AKS (`kube-audit-admin`), PostgreSQL logs → Log Analytics | Terraform diagnostic settings |

## 8. Design decisions

| ADR | Decision |
|-----|----------|
| [0001](adr/0001-github-oidc-federation.md) | GitHub Actions authenticates to Azure with OIDC federation |
| [0002](adr/0002-terragrunt-unit-layout.md) | Terragrunt units per component, one state file per unit |
| [0003](adr/0003-gateway-api-and-migrations.md) | Gateway API for ingress; init-container migrations with an advisory lock |
| [0004](adr/0004-ci-cd-pipeline.md) | CI/CD: build once, promote by digest, gate prod |
| [0005](adr/0005-genai-incident-triage.md) | GenAI incident triage as a bounded, read-only agent |
