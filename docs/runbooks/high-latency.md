# Runbook: high latency

**Alerts:** `SortieTrackerHighLatency` (p95 above 500 ms for 10 minutes), Azure `postgres-cpu`, `aks-node-cpu`.

## 1. Confirm

The Grafana *Latency p50/p95/p99* panel shows the trend. `log_analyzer.py` reports per-route p95,
which shows whether one route is slow or all of them are.

## 2. Find the cause

| Pattern | Likely cause | Action |
|---------|--------------|--------|
| All routes slow; pod CPU near requests; HPA at max | Under-provisioned | Raise `autoscaling.maxReplicas`; check node autoscaler headroom |
| HPA scaling but new pods `Pending` | Out of nodes | Raise `node_max_count` in `env.hcl` |
| One list route slow (`/api/v1/sorties`) | Unfiltered query or missing index | Check `pg_stat_statements` on the server; add an index through an Alembic migration |
| PostgreSQL CPU above 80% | Database bound | Scale the SKU (prod: `GP_Standard_D2ds_v5`), tune the query |
| Latency jumps after a deploy | Code regression | Roll back ([high-error-rate.md](high-error-rate.md)) |

## 3. Verify

p95 drops back below 500 ms and the alert resolves.

## Rehearse

`scripts/chaos.sh load inject` (20 clients for 5 minutes), then watch with
`kubectl -n sortie-tracker get hpa -w`.
