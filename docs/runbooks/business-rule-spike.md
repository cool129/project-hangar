# Runbook: spike in rejected requests (business rules)

**Alert:** `SortieTrackerBusinessRuleSpike` (info). **Not an outage:** the API is correctly refusing
requests (HTTP 409 with a `rule` field). The question is *who* is sending them and *why*.

## 1. Identify rule and caller

```bash
python scripts/log_analyzer.py --kubectl --since 30m        # "Spike in rejected requests: <rule>"
python scripts/log_analyzer.py --kubectl --trace <request-id>  # caller IP and path at the gateway
```

## 2. Interpret

| Rule | Usually means |
|------|---------------|
| `aircraft_not_mission_capable` | An upstream scheduling system is using stale fleet status: it is scheduling grounded (NMC) aircraft |
| `aircraft_already_airborne` | Duplicate launch messages: a client retrying without idempotency |
| `invalid_status_transition` | Client state machine out of sync (e.g. landing a sortie that was never launched) |
| `unique_constraint` | Retried creates with the same mission number |

## 3. Act

- Contact the owning mission team with the rule, counts, time range and example request IDs.
- If it degrades the platform (high request rate), rate-limit the caller at the gateway with an
  Envoy Gateway `BackendTrafficPolicy`.
- If the rejections look wrong (a valid request rejected), treat it as a bug: SEV3, with app owner review.

## Rehearse

`scripts/chaos.sh bad-client inject`, then `recover`.
