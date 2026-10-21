# Runbook: high error rate (error budget burn)

**Alerts:** `SortieTrackerErrorBudgetFastBurn` (critical, pages) and `SortieTrackerErrorBudgetSlowBurn` (warning).
**SLO:** 99% of API requests succeed over 30 days. A fast burn means the monthly budget is gone in about 2 days.

## 1. Confirm

- Grafana: the *Error ratio* and *Responses by status* panels show which status code is climbing.
- `python scripts/log_analyzer.py --kubectl --since 30m` reports the top signatures and findings.

## 2. Find the cause

| Signal | Likely cause | Go to |
|--------|--------------|-------|
| `503` + `database_unavailable` signature, `/readyz` failing | PostgreSQL unreachable | [db-connectivity.md](db-connectivity.md) |
| Gateway 5xx **with no upstream**, app logs quiet | No ready pods behind the Service | [pod-failures.md](pod-failures.md) |
| `500` + `unhandled_exception` signature | Application bug, usually right after a deploy | below |
| Errors started at a deploy time (`helm -n sortie-tracker history sortie-tracker`) | Bad release | below |

Follow a failing request end to end:
`python scripts/log_analyzer.py --kubectl --trace <request-id>` (IDs are in the signature output).

## 3. Mitigate

- **Bad release:** `helm -n sortie-tracker rollback sortie-tracker 0 --force-conflicts --wait`, or re-run the `deploy`
  workflow with the previous SHA. Migrations are backward compatible, so rolling back the app is safe.
- **Dependency outage:** follow the matching runbook. The API already fails fast with 503 and recovers by itself.

## 4. Verify

The error ratio drops below 1% and the fast-burn alert resolves (about 5 minutes after recovery).

## 5. Follow up

SEV1 or SEV2 means writing a postmortem. Add a regression test for unhandled exceptions.
