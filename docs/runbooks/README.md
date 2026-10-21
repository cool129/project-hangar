# Runbooks

Every alert (`runbook_url` annotation) and every `log_analyzer.py` finding links
to one of these. Each runbook follows the same shape: **confirm → find the
cause → mitigate → verify → follow up.** Mitigate first, investigate later:
restoring service beats a perfect diagnosis.

| Runbook | Triggered by | Rehearsed with |
|---------|--------------|----------------|
| [high-error-rate.md](high-error-rate.md) | `SortieTrackerErrorBudgetFastBurn` / `SlowBurn` | `chaos.sh db-outage` |
| [db-connectivity.md](db-connectivity.md) | `SortieTrackerDatabaseErrors`, Azure `postgres-connections-failed` | `chaos.sh db-outage` |
| [pod-failures.md](pod-failures.md) | `SortieTrackerNoReadyPods`, `RolloutStuck`, `CrashLooping` | `chaos.sh bad-image`, `oom`, `pod-kill` |
| [high-latency.md](high-latency.md) | `SortieTrackerHighLatency`, Azure `postgres-cpu` | `chaos.sh load` |
| [business-rule-spike.md](business-rule-spike.md) | `SortieTrackerBusinessRuleSpike` | `chaos.sh bad-client` |
| [migration.md](migration.md) | planned change (legacy VM to AKS) | `make migration-rehearsal` |

## First five minutes, any alert

```bash
make aks-credentials ENV=<env>
python scripts/log_analyzer.py --kubectl --since 30m            # findings + runbook links
python scripts/log_analyzer.py --kubectl --since 30m --ai       # + AI incident draft (verify it!)
kubectl -n sortie-tracker get deploy,pods,hpa
kubectl -n sortie-tracker get events --sort-by=.lastTimestamp | tail -20
```

Grafana: **Sortie Tracker: Service & SLO** dashboard (`kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`).

## Severity

| SEV | Meaning | Response |
|-----|---------|----------|
| SEV1 | API down, or more than 25% of requests failing | page; incident call; status update every 30 min |
| SEV2 | SLO fast burn, or a core workflow broken | page; fix within hours |
| SEV3 | Degraded or partial impact | ticket; next business day |
| SEV4 | No user impact | backlog |

Every SEV1 and SEV2 gets a blameless postmortem ([template](postmortem-template.md)).
