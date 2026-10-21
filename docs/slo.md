# Sortie Tracker service level objectives

| SLI | Definition (Prometheus) | SLO | Window |
|-----|-------------------------|-----|--------|
| **Availability** | non-5xx API responses ÷ all API responses, excluding `/healthz`, `/readyz`, `/metrics` | **99%** | 30 days, rolling |
| **Latency** | p95 of `http_request_duration_seconds` for API routes | **< 500 ms** | 5-minute windows |

**Error budget:** 1% of requests, roughly 7 hours of full outage per 30 days. Probe and
scrape traffic is excluded, so a flapping readiness probe cannot burn the budget
(covered by a promtool unit test).

## Alerting policy (multi-window, multi-burn-rate)

| Alert | Condition | Budget gone in | Action |
|-------|-----------|----------------|--------|
| `ErrorBudgetFastBurn` | burn above 14.4× on the 1h **and** 5m windows, for 2m | about 2 days | page (critical) |
| `ErrorBudgetSlowBurn` | burn above 6× on the 6h **and** 30m windows, for 15m | about 5 days | ticket (warning) |

Requiring a long *and* a short window means pages only for problems that are both
significant and still happening, and they resolve within minutes of recovery.
Symptom alerts (budget burn) page; cause alerts (`DatabaseErrors`, `NoReadyPods`)
route the responder to the right runbook.

## Budget policy

- **Over 50% of budget remaining:** ship freely.
- **25 to 50%:** releases need a rollback plan in the PR.
- **Under 25%:** reliability work only until the budget recovers; feature deploys need the app owner's sign-off.

Rules: `deploy/helm/sortie-tracker/files/prometheus-rules.yaml`. Tests: `tests/prometheus/rules-test.yaml` (`make alerts-test`).
