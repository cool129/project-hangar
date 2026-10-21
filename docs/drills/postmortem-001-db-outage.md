# Postmortem 001: PostgreSQL egress drift, then a database restart, takes the API down

> Blameless postmortem of **chaos drill 001**, run on the local kind platform on
> 2026-10-21. The failure was injected on purpose; everything else (detection,
> behaviour, numbers) is real and comes from the evidence files in this folder.

| | |
|---|---|
| **Severity** | SEV1 (API unavailable for every request) |
| **Duration** | 89 s of user impact (05:39:39 to 05:41:08 UTC, run 1) |
| **Trigger** | NetworkPolicy lost its PostgreSQL egress rule, then PostgreSQL restarted |
| **Detection** | Readiness failed within about 15 s; `log_analyzer.py` top finding pointed at `db-connectivity.md` |
| **Evidence** | [run 1 report](drill-001-run1-before-fix.txt), [run 2 report](drill-001-run2-after-fix.txt), `scripts/chaos.sh db-outage`, `deploy/local/chaos-drill.sh` |

## Summary

A change removed the rule allowing the API pods to reach PostgreSQL on 5432.
**Nothing broke:** NetworkPolicies only gate *new* connections, and the pods'
pooled connections stayed up. When PostgreSQL later restarted (as Azure does in
maintenance windows), every pooled connection dropped, no new ones could be
opened, and all requests failed until the rule was restored.

The API did fail with the designed `503 Database unavailable`, but **slowly: each
request hung for 5 seconds**. The drill also found five defects in the platform
and its tooling. Four were fixed and re-verified the same day.

## Impact (run 1, steady ~4 req/s)

- 18 of 486 API requests returned 503. **The 3.7% understates the impact:** each failing request
  blocked for 5.0 s (5014 to 5039 ms), so client throughput collapsed from about 3.9 req/s to about
  0.2 req/s. Clients sent 20× fewer requests *because* they were waiting.
- Both pods went `0/1` (not ready). No restarts, as designed: liveness does not check the database.

## Timeline (UTC, run 1)

| Time | Event |
|------|-------|
| 05:38:28 | Steady traffic starts through the Envoy gateway |
| 05:39:3x | PostgreSQL egress rule removed. **Latent: no errors, readiness still green** |
| 05:39:39 | PostgreSQL restarts; first `database_unavailable` (503 after 5.0 s) |
| ~05:39:55 | Both pods not ready (3 failed probes × 5 s) |
| 05:39:55 to 05:41:08 | Envoy panic routing keeps sending traffic to the not-ready pods; 503s at 5 s each |
| 05:41:08 | Egress rule restored; pods ready; traffic normal within 10 s |

## What we learned

| # | Finding | How we know | Status |
|---|---------|-------------|--------|
| 1 | **Policy drift is latent.** Removing an egress rule breaks nothing until connections recycle (pod restart, scale-out, DB restart, `pool_recycle` = 30 min). The cause and the outage can be hours apart. | Pods stayed `1/1` with the rule gone; a *new* TCP connection from the pod timed out while `/readyz` passed | **Open**: detect drift (below) |
| 2 | **The API failed slowly.** DB `connect_timeout` (5 s) was longer than the readiness probe timeout (3 s), so requests hung 5 s and probes timed out instead of getting the app's 503. SQLAlchemy's default `pool_timeout` (30 s) was also unset. | Run 1: every 503 took 5014 to 5039 ms | **Fixed**: `connect_timeout` 2 s, `pool_timeout` 5 s, regression test. Run 2: 503s in 2014 to 2109 ms, 2.3× more requests answered |
| 3 | **Envoy panic mode routes to not-ready pods.** With 0% healthy endpoints, Envoy (default 50% panic threshold) sends traffic to all endpoints instead of failing fast at the edge. | Envoy admin: both hosts `eds_status_draining`; `lb_healthy_panic` counter incremented during the outage | **Open**: decide (below) |
| 4 | **Helm 4 rollbacks fail after manual changes.** Helm 4 applies server-side; the hotfix (`kubectl patch`) took ownership of `.spec.egress`, so `helm rollback` was refused with a field-manager conflict. The standard mitigation failed. | Rollback error: `conflict with "kubectl-patch" ... .spec.egress` | **Fixed**: `--force-conflicts` in `deploy.sh`, `chaos.sh recover-all` and the runbooks |
| 5 | **Triage tooling bugs.** `kubectl logs -l` silently caps at 10 lines per container (overriding `--since`); the analyzer counted 2 s *failed* requests as "slow routes", double-reporting one outage; it also reported hour-old Kubernetes events from already-resolved drills, and treated normal startup-probe failures during boot as pod problems | First analysis covered 12 s of a 5-minute window; run 2 raised 3 false latency findings; a later `bad-client` drill showed stale "pod problems" | **Fixed**: `--tail=-1`; latency SLI over successful requests; events limited to the `--since` window; startup-probe noise ignored; a regression test for each |
| 6 | Drill artifact: the local PostgreSQL stand-in used `emptyDir`, so its restart wiped the database (`ProgrammingError`) | First attempt's post-recovery 500s | **Fixed**: StatefulSet with a persistent volume, like the managed service |

**Alerting check (run 1):** `SortieTrackerNoReadyPods` (`for: 1m`) would page about 75 s into the
outage. `DatabaseErrors` (`for: 2m`) and the budget-burn alerts would *not* fire for a 90 s
event. That is by design for burn alerts, but worth knowing: **readiness-based alerting
caught this, error-ratio alerting did not**, partly because of finding 2.

## Action items

| Action | Type | Status |
|--------|------|--------|
| DB `connect_timeout` 2 s below probe timeout; explicit `pool_timeout`; regression test | mitigate | **Done**, verified by re-drill |
| `--force-conflicts` for Helm 4 deploys and rollbacks; runbooks updated | mitigate | **Done** |
| Analyzer: `--tail=-1`; latency over successful requests | detect | **Done** |
| Drift detection: alert on `NetworkPolicy` changes not made by the CI identity (AKS `kube-audit-admin` logs are already in Log Analytics), and/or continuous reconciliation (Flux or Argo CD) so drift is reverted, not discovered | detect / prevent | Open |
| Decide on Envoy fail-fast: `BackendTrafficPolicy` with `healthyPanicThreshold: 0` returns instant 503s when no pod is ready, at the cost of a full outage if readiness ever misreports. Record in an ADR | mitigate | Open |
| App-level circuit breaker: after N consecutive DB failures, return 503 immediately for a few seconds instead of attempting a connection per request | mitigate | Open |
| Run `db-outage` against dev AKS with `CHAOS_PG_SERVER` (real Azure restart) | verify | Open |

## What went well

- The designed degradation worked: readiness took pods out of service, liveness did not restart them, recovery was automatic within 10 s, and no data was lost.
- `log_analyzer.py` ranked the root cause first and linked the right runbook. The request IDs in its output led straight to the failing requests.
- Rehearsing found six issues in about 30 minutes of drilling, and none of them in production.
