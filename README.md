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
| 0     | Repo standards, remote state, GitHub OIDC          | In progress |
| 1     | Terraform modules + Terragrunt environments        | Planned     |
| 2     | Sortie Tracker app + Docker                        | Planned     |
| 3     | Helm chart + AKS platform add-ons                  | Planned     |
| 4     | GitHub Actions CI/CD                               | Planned     |
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
`.env.hangar`, which is gitignored and read automatically by `make`.

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
