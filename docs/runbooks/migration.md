# Runbook: migrate Sortie Tracker from the legacy VM to AKS

**Audience:** platform operator, with the mission team's app owner on the call.
**Expected window:** 15 minutes. Data copy takes seconds; most of the time is verification.
**Rehearsed by:** `make migration-rehearsal` locally, and on every PR (`ansible` workflow).

## Architecture during the migration

```
                 before                                     after
clients ─▶ legacy VM :8000 (systemd app + local PG)    clients ─▶ legacy VM :8000 (nginx proxy)
                                                                     │
                                                                     ▼
                                                       AKS gateway ─▶ pods ─▶ Azure PG (private)
```

Clients keep using the legacy address. Cutover turns it into a proxy (the
strangler pattern), so no client has to change on migration night. Moving
clients to the gateway's DNS name afterwards is a separate, non-urgent change.

## T-1 day: prerequisites

| Check | How |
|-------|-----|
| Infra applied for the environment | `infra` workflow green on `main`; `make infra-output ENV=<env>` |
| App deployed on AKS and healthy | `deploy` workflow green; `curl http://<gateway>/healthz` |
| AKS schema at the same Alembic revision as legacy | migrate_db.py preflight enforces this |
| Legacy host converged and idempotent | `ansible-playbook playbooks/site.yml -l env_<env> --check --diff` shows no changes |
| Operator access | `az login`, `make aks-credentials ENV=<env>`, SSH from an allowed CIDR |
| Rehearsal green on the exact commit being used | `ansible` workflow on that SHA |
| Stakeholders notified of the maintenance window | mission team channel |

## Go / no-go

**Go only if** every prerequisite passes. **Abort** (no rollback needed, legacy
still in charge) if any preflight fails or the report is not `PASS`.

## Execute

```bash
scripts/cutover.sh migrate <env>
```

| Step | What happens | If it fails |
|------|--------------|-------------|
| 1. Preflight | tools, Azure session, kube-context, gateway health | fix and re-run; nothing has changed |
| 2. Credentials | target DB secrets read from Key Vault into the process env only | check Key Vault RBAC |
| 3. Quiesce target | AKS deployment scaled to 0 | replicas restored automatically on exit |
| 4. Freeze + migrate | legacy service stopped; `migrate_db.py` copies data in one transaction and checksum-verifies every table | playbook **restarts the legacy service automatically**; target holds no partial data |
| 5. Verify on AKS | AKS scaled back; readiness must report the migrated aircraft count | run `scripts/cutover.sh rollback <env>` |
| 6. Cutover | legacy port proxies to the gateway (`X-Served-By: legacy-cutover-proxy`) | `scripts/cutover.sh rollback <env>` |

The migration report (JSON + Markdown, with row counts, checksums, dump SHA-256
and phase timings) is saved under `reports/migration/<run-id>/`. Attach it to the
change ticket.

## Verify (post-cutover, ~5 minutes)

- `curl -sI http://<legacy-ip>:8000/healthz`: `X-Served-By: legacy-cutover-proxy`, `environment` is `<env>`
- Grafana: request rate is flowing through the gateway; no 5xx
- Spot-check a known sortie by mission number on the legacy URL and on the gateway
- `ansible-playbook playbooks/migrate.yml -l env_<env> -e migration_validate_only=true -e migration_freeze_source=false`
  re-confirms source == target (valid only until new writes arrive)

## Rollback

```bash
scripts/cutover.sh rollback <env>
```

This removes the proxy and restarts the legacy service on its untouched local
database. **Writes accepted by AKS after cutover are not copied back.**
If rollback happens after real traffic:

1. Export new rows from Azure PG: `created_at > '<cutover time>'` on `aircraft` and `sorties`.
2. The app owner reviews them and re-applies them to legacy through the API (business rules still enforced).
3. Record the reconciliation in the change ticket.

## Decommission (after a 2-week soak)

1. Final `--validate-only` comparison is no longer meaningful (data has diverged). Archive the last legacy `pg_dump` to Blob storage with a retention policy instead.
2. Move clients to the gateway DNS name; then remove the `legacy-vm` unit from Terragrunt.
3. Close the change ticket with the migration report attached.
