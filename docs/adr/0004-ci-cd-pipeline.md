# ADR 0004: CI/CD on GitHub Actions: build once, promote by digest, gate prod

- **Status:** Accepted
- **Date:** 2026-10-20

## Context

The pipeline has to ship infrastructure and application changes to two
environments without stored cloud credentials, with prod changes approved by a
human, and with a supply chain an auditor can reason about.

## Decision

### Workflows

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `quality` | every PR / main | pre-commit hooks (gitleaks, fmt, shellcheck, yamllint, tflint), actionlint, zizmor |
| `app` | `app/**` | ruff, unit + PostgreSQL integration tests, build, Trivy gate, SARIF + SBOM; on main: push to dev ACR → deploy dev → **approval** → promote → deploy prod |
| `infra` | `infra/**` | fmt, validate, tflint, Terragrunt HCL, Checkov; PR: plan dev+prod as sticky PR comments; main: apply dev → **approval** → apply prod |
| `k8s` | `deploy/**`, `app/**` | helm lint, kubeconform (incl. CRDs), Checkov; full kind end-to-end test |
| `deploy` | reusable + manual | promote image, Helm deploy, smoke test via gateway, roll back on failure |

### Principles

- **No secrets.** Azure access is OIDC only. Plans authenticate as
  `pull_request`; applies and deploys authenticate as a GitHub Environment, so
  only an approved prod job can obtain a prod-capable token.
- **Build once, promote by digest.** The image is built and scanned once. Prod
  receives the same digest through a server-side `az acr import`; nothing is
  rebuilt between environments.
- **Supply chain.**
  - Every third-party action is pinned to a full commit SHA. Tags are mutable,
    and `aquasecurity/trivy-action` tags were force-pushed to malicious commits
    in March 2026.
  - CLI tools are downloaded at pinned versions and verified against SHA-256
    values committed in `scripts/ci/tool-versions.env`; a mismatch fails the job.
  - Service container images are pinned by digest.
  - Dependabot proposes updates with a 14-day cooldown.
  - An SBOM (CycloneDX) is published for every image.
- **Least privilege.** Workflows default to `permissions: {}`; each job requests
  only what it uses, with a comment saying why. Checkout never persists
  credentials.
- **Safe concurrency.** One Terraform run and one deployment per environment at
  a time. A deployment is never cancelled midway.

## Consequences

- GitHub repository variables (set by `bootstrap/setup-oidc.sh`) and a `prod`
  environment with required reviewers must exist before the first run.
- Workflows trigger on `main`; the repository's default branch must be `main`.
- Fork PRs cannot run plans (no OIDC token), by design.
- The job-level gates are GitHub Environments. A regulated program would add
  branch protection requiring the `quality`, `app`, `infra` and `k8s` checks.
