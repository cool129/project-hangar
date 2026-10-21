# Architecture decision records

Each ADR records one significant decision: its context, the options considered, the choice,
and its consequences, including the trade-offs accepted. New ADRs take the next number;
superseded ones stay and link forward.

| ADR | Decision | Status |
|-----|----------|--------|
| [0001](0001-github-oidc-federation.md) | GitHub Actions authenticates to Azure with OIDC federation | Accepted |
| [0002](0002-terragrunt-unit-layout.md) | Terragrunt units per component, one state file per unit | Accepted |
| [0003](0003-gateway-api-and-migrations.md) | Gateway API for ingress; init-container migrations with an advisory lock | Accepted |
| [0004](0004-ci-cd-pipeline.md) | CI/CD: build once, promote by digest, gate prod | Accepted |
| [0005](0005-genai-incident-triage.md) | GenAI incident triage as a bounded, read-only agent | Accepted |

**Proposed next** (from [postmortem 001](../drills/postmortem-001-db-outage.md)): Envoy fail-fast
(`healthyPanicThreshold: 0`) vs panic routing; drift detection (audit-log alert vs GitOps reconciliation).
