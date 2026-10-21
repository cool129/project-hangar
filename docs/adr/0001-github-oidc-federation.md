# ADR 0001: GitHub Actions authenticates to Azure with OIDC federation

- **Status:** Accepted
- **Date:** 2026-10-20

## Context

The CI/CD pipelines must run Terraform, push images to ACR and deploy to AKS.
The usual approach, a service principal client secret stored as a GitHub secret,
creates a long-lived credential that can leak, has to be rotated, and gives no
indication of which workflow used it.

## Decision

Use **workload identity federation (OIDC)**. GitHub issues a short-lived signed
token for each job; Entra ID trusts it only when the token's `subject` matches a
federated credential on the `sp-hangar-github` app registration:

| Subject                                   | Used by                               |
|-------------------------------------------|---------------------------------------|
| `repo:<owner>/<repo>:pull_request`        | `terraform plan`, tests, image scans  |
| `repo:<owner>/<repo>:ref:refs/heads/main` | image push on merge                   |
| `repo:<owner>/<repo>:environment:dev`     | dev apply/deploy                      |
| `repo:<owner>/<repo>:environment:prod`    | prod apply/deploy (requires approval) |

Privileges follow least privilege as far as practical:

- `Contributor` on the subscription (Terraform creates resource groups).
- `Role Based Access Control Administrator` with an **ABAC condition** restricting
  it to an explicit list of workload roles (AcrPull, Key Vault Secrets User, ...),
  instead of `Owner` or unrestricted `User Access Administrator`.
- `Storage Blob Data Contributor` on the state account only. Shared-key access to
  that account is disabled, so state is reachable only through Entra ID.

## Consequences

- No secrets to store, rotate or leak; the GitHub repo holds only identifiers.
- Prod deployments can only obtain a token from a job bound to the `prod`
  environment, which is gated by required reviewers.
- Adding a new delegable role means updating `bootstrap/setup-oidc.sh` and
  re-creating the conditioned assignment, which is deliberate friction.
- Subscription-level Contributor is broader than ideal; in a real program this
  would be scoped to a management group / landing-zone subscription per mission team.
