# Runbook: API cannot reach PostgreSQL

**Alerts:** `SortieTrackerDatabaseErrors` (critical), Azure `alert-hangar-<env>-postgres-connections-failed`.
**What users see:** `503 {"detail": "Database unavailable"}`. Pods stay alive (`/healthz` passes)
but are not ready (`/readyz` fails), so Kubernetes stops routing to them instead of restarting them.

## 1. Confirm

```bash
python scripts/log_analyzer.py --kubectl --since 15m      # finding: "PostgreSQL unreachable from the API pods"
kubectl -n sortie-tracker get pods                         # READY 0/1, RESTARTS unchanged
```

## 2. Find the cause: work outward from the pod

| Check | Command | Healthy |
|-------|---------|---------|
| Error type in logs | signature detail: `ConnectionTimeout` vs `password authentication failed` | |
| DNS resolves the private endpoint | `kubectl -n sortie-tracker debug -it deploy/sortie-tracker --image=busybox:1.37 -- nslookup <fqdn>` | `10.x.8.x` address |
| NetworkPolicy still allows 5432 egress | `kubectl -n sortie-tracker get networkpolicy sortie-tracker -o yaml` | egress rule to the db subnet CIDR |
| Server state | `az postgres flexible-server show -g rg-hangar-<env> -n <name> --query state` | `Ready` |
| Server metrics | Azure portal: CPU, connections, storage | under 80% |
| Credentials | Key Vault `postgres-admin-password` updated recently? CSI rotation interval is 2 minutes | |

Mapping:
- **Timeout + NetworkPolicy missing its egress rule:** policy drift. Mitigate with `helm -n sortie-tracker rollback sortie-tracker <current-revision> --force-conflicts` (or `scripts/chaos.sh recover-all`), which re-applies the desired state. `--force-conflicts` is required because Helm 4 applies server-side and the manual change now owns those fields.
- **Timeout + server not `Ready`:** Azure-side issue or failover in progress. HA failover in prod takes 60 to 120 seconds; check Azure Service Health.
- **`password authentication failed`:** the secret was rotated without the server password (or the reverse). Reconcile with `terragrunt apply` in `infra/live/<env>/postgres`.
- **`too many connections`:** pool size × replicas exceeds `max_connections`. Lower `DB_POOL_SIZE` or scale the SKU.

## 3. Verify

`/readyz` passes on every pod, `SortieTrackerDatabaseErrors` resolves, and
`log_analyzer.py` shows no `database_unavailable` lines after the fix time.

## Rehearse

`scripts/chaos.sh db-outage inject`, then `scripts/chaos.sh db-outage recover`. This removes the
NetworkPolicy egress rule, the most realistic config-drift failure.
