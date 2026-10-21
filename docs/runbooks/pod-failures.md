# Runbook: pods not ready, rollout stuck, crash loops

**Alerts:** `SortieTrackerNoReadyPods` (critical), `SortieTrackerRolloutStuck`, `SortieTrackerCrashLooping` (warning).

Rollouts use `maxUnavailable: 0`, so a broken release usually means **new pods
fail while old pods keep serving**: a stuck rollout, not an outage. An outage
(`NoReadyPods`) needs every pod down, for example a DB outage combined with restarts.

## 1. Confirm

```bash
kubectl -n sortie-tracker get deploy,rs,pods -o wide
kubectl -n sortie-tracker describe pod <new-pod>          # Events at the bottom
python scripts/log_analyzer.py --kubectl --since 30m       # surfaces image-pull/OOM events
```

## 2. Find the cause

| Pod state / event | Cause | Fix |
|-------------------|-------|-----|
| `ImagePullBackOff`, `ErrImagePull` | Tag missing in ACR, or kubelet lost `AcrPull` | Roll back; check `az acr repository show-tags -n <acr> --repository sortie-tracker` |
| `OOMKilled` (last state), `CrashLoopBackOff` | Memory limit too low for the workload | Roll back; raise `resources.limits.memory` in values |
| `Init:CrashLoopBackOff` (`migrate` container) | Failing Alembic migration | `kubectl logs <pod> -c migrate`; fix the migration; never edit an applied revision |
| `Running` but `0/1` ready | Readiness failing; usually the database | [db-connectivity.md](db-connectivity.md) |
| `Pending`, `FailedScheduling` | No node capacity; autoscaler at `node_max_count` | Raise max count in `env.hcl`, or reduce requests |
| `CreateContainerConfigError` / CSI mount errors | Key Vault access (workload identity, RBAC) | `kubectl describe pod`; check the federated credential subject and the `Key Vault Secrets User` role |

## 3. Mitigate

```bash
kubectl -n sortie-tracker rollout undo deploy/sortie-tracker      # fastest
helm -n sortie-tracker rollback sortie-tracker 0 --force-conflicts --wait           # restores the whole release
```

## 4. Verify

`kubectl -n sortie-tracker rollout status deploy/sortie-tracker` completes, and
available replicas equal desired on the dashboard.

## Rehearse

`scripts/chaos.sh bad-image|oom|pod-kill inject`, then `recover`.
