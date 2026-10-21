# Onboarding a mission application to HANGAR

This is the repeatable path a mission team follows to move an application onto the
platform. Sortie Tracker is the worked example; every step links to the files it used.
Expect **one to two weeks** for a typical stateless API with a PostgreSQL database.
Most of that is the team's own code changes in step 2.

## Who does what

| Platform team (us) | Mission team (you) |
|--------------------|--------------------|
| Cluster, gateway, monitoring stack, Key Vault, PostgreSQL, CI templates | Application code, Dockerfile, Helm values, SLOs, runbooks |
| Reviews your onboarding PRs; runs the cutover with you | Owns the app's alerts and on-call after go-live |

## Step 0: Discovery (day 1, a one-hour call)

Fill in this table together. It decides the rest of the path.

| Question | Sortie Tracker answer | Why it matters |
|----------|-----------------------|----------------|
| Runtime and how it starts | Python 3.13, `uvicorn` | Base image, probes |
| State | PostgreSQL 16, about 10 MB | Managed PG + `migrate_db.py`, or a different store |
| Secrets it needs | DB host, user, password | Key Vault entries + CSI mount |
| Inbound traffic | HTTP API, ~5 req/s | Gateway route, HPA bounds |
| Outbound dependencies | Database only | NetworkPolicy egress allow-list |
| Schema management | Alembic | Migrations in an init container |
| Data classification | CUI-like (unclassified) | Environment and controls |
| Current hosting | Hand-built VM, systemd | Migration rehearsal path |

**Not a fit as-is:** apps that write to local disk, need root or privileged containers, or
hold long-lived sockets without health checks. Those go through an architecture review first.

## Step 1: Platform readiness (platform team, about 1 day)

1. **Namespace:** add the app's namespace to `deploy/platform/namespaces.yaml` with
   `pod-security.kubernetes.io/enforce: restricted` and `hangar.io/gateway-access: "true"`.
2. **Workload identity:** copy `infra/live/_envcommon/app-identity.hcl` to
   `<app>-identity.hcl` and change `workload_name`, `namespace` and `service_account_name`.
   Add two-line units under `infra/live/{dev,prod}/`. The PR's `infra` workflow posts the plan.
3. **Data:** new database or schema on the Flexible Server; secrets land in Key Vault with
   the names the app reads.

## Step 2: Make the app platform-ready (mission team)

The [12-factor](https://12factor.net/) checklist, as enforced by the platform:

- [ ] **Container** builds from a pinned base, runs as non-root, works with a read-only root
      filesystem (write only to `/tmp`), and has no package manager at runtime.
      Reference: `app/Dockerfile`.
- [ ] **Config** from environment variables *or* files in `SECRETS_DIR`, using the Key Vault secret
      names. Reference: `app/src/sortie_tracker/config.py`.
- [ ] **Probes:** `/healthz` (process alive, **no dependency checks**) and `/readyz` (dependencies
      reachable). Dependency timeouts must be shorter than the probe timeout (see
      [postmortem 001](drills/postmortem-001-db-outage.md)).
- [ ] **Logs:** one JSON object per line to stdout, including the incoming `X-Request-ID`.
- [ ] **Metrics:** Prometheus `/metrics` with request count and latency by *route template*.
- [ ] **Migrations:** backward compatible (expand/contract), safe to run concurrently (advisory lock).
- [ ] **Tests:** unit tests run without external services; integration tests run against the real
      database in CI.

## Step 3: Deploy to dev (half a day)

1. Copy `deploy/helm/sortie-tracker/` as the starting chart; change names, ports, probes and
   `networkPolicy.postgresCidr`. Keep the security context unchanged: PSS `restricted` will
   reject anything weaker.
2. Write the SLOs in `files/prometheus-rules.yaml` and add promtool tests under
   `tests/prometheus/`. Start from the Sortie Tracker targets and adjust.
3. Run `make k8s-local-e2e` locally to prove the chart works under the platform's real policies
   before touching Azure.
4. Add the app to `.github/workflows/app-ci.yml` (or copy it). Merge to `main` and the pipeline
   builds, scans, pushes and deploys to dev.

**Exit criteria:** the dev smoke test passes through the gateway; dashboards show traffic;
`chaos.sh pod-kill` and `db-outage` behave as designed.

## Step 4: Migrate data and cut over (one scheduled window)

1. Converge the legacy host with Ansible (`site.yml`) so it is known, hardened and idempotent.
2. Run the migration rehearsal (`make migration-rehearsal`) on the exact commit you will use.
3. Follow [runbooks/migration.md](runbooks/migration.md): go/no-go, `scripts/cutover.sh migrate <env>`,
   verify, then keep the strangler proxy for a 2-week soak.

## Step 5: Operate (ongoing)

- [ ] Runbooks for each alert (copy the structure in `docs/runbooks/`).
- [ ] One chaos drill per quarter, with a postmortem for anything surprising.
- [ ] Error-budget policy agreed with the product owner ([slo.md](slo.md)).
- [ ] Decommission the legacy VM after the soak (remove its Terragrunt unit).

## Definition of done

The app runs in prod behind the gateway with no secrets outside Key Vault, passes
every CI gate, has SLO alerts with runbooks, has survived at least one drill, and its
legacy host is gone.
