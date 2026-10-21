# ADR 0002: Terragrunt units per component, one state file per unit

- **Status:** Accepted
- **Date:** 2026-10-20

## Context

The platform has two environments (dev, prod) built from the same eight
components. Plain Terraform would mean either one large root module per
environment (big blast radius, slow plans, one lock for everything) or
hand-copied root modules that drift apart.

## Decision

```
infra/
  modules/                 pure, reusable Terraform modules (no backend, no provider config)
  live/
    root.hcl               backend + provider generation, naming, tags, admin identities
    _envcommon/<unit>.hcl  module source, dependencies + mocks, input wiring (written once)
    <env>/env.hcl          the only per-environment knobs: sizes, SKUs, CIDRs, retention
    <env>/<unit>/terragrunt.hcl   two include blocks, identical across environments
```

Units: `foundation → network, acr, keyvault → aks, postgres, legacy-vm → app-identity`.

- **One state file per unit** (`<env>/<unit>/terraform.tfstate`): a bad AKS change
  can't corrupt network state, and plans touch only what changed.
- **Dependencies are explicit** (`dependency` blocks). `run --all` applies in graph
  order and destroys in reverse. Mock outputs let a brand-new environment be
  planned end to end before anything exists.
- **Environment differences live in one file.** Promoting dev → prod is a review of
  `env.hcl`, not of eight copied directories.
- **Onboarding a new mission app** = copy `_envcommon/app-identity.hcl` and add a
  two-line unit. This is the "onboarding path" made concrete.

## Security trade-offs accepted for the portfolio budget

Public endpoints remain on the AKS API server, Key Vault and ACR because CI uses
GitHub-hosted runners with dynamic IPs. Each is Entra ID-only (local accounts,
admin users and shared keys are disabled) and each Checkov skip is justified
inline. A production program would add private endpoints + a private cluster
and run pipelines on self-hosted runners inside the VNet.

## Consequences

- `terragrunt` is a required tool for operators and CI.
- First-run plans show mocked upstream values; apply resolves real outputs.
- Changing a module's outputs requires updating mock outputs in `_envcommon`.
