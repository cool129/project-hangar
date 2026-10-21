# Demo script

Two versions: a **5-minute recorded walkthrough** for a portfolio link or interview
follow-up, and a **15-minute live demo** that runs entirely on a laptop (no Azure bill).

## Prep (once, before recording)

```bash
make app-build                         # image for local demos
make k8s-local-e2e                     # kind cluster with gateway + app (KEEP_CLUSTER=true by default)
make app-up app-seed                   # compose stack at http://localhost:18080 (for the API tour)
```

Open in tabs: the GitHub repo README; a PR showing the `infra` plan comment and green checks;
[postmortem-001](drills/postmortem-001-db-outage.md); `localhost:18080/docs`.
Terminal at 120 columns, large font.

## 5-minute recorded walkthrough

| Time | Show | Say (key points, not a script to read) |
|------|------|-----------------------------------------|
| 0:00 to 0:30 | README top section + overview diagram | "A platform for onboarding Air Force mission apps onto Azure, shown end to end: a legacy app on a hand-built VM, moved onto AKS with no stored credentials anywhere, rehearsed and monitored." |
| 0:30 to 1:15 | `infra/live/` tree, one two-line unit, `env.hcl`, the PR plan comment | "Terraform modules, Terragrunt per environment: nine units, one state file each. Dev and prod differ in one file. Every PR posts a plan for both." |
| 1:15 to 2:00 | `.github/workflows/app-ci.yml`, then a run graph | "GitHub OIDC to Entra ID, so there are no secrets in the repo. The image is built and scanned once, then promoted to prod *by digest* behind an approval. Actions are pinned to commit SHAs; the Trivy tags were hijacked in March 2026." |
| 2:00 to 2:45 | `make migration-rehearsal` output (pre-recorded), `report.md` | "Ansible hardens and converges the legacy VM. `migrate_db.py` copies data in one transaction and checksums every table. The rehearsal changes one row out of 300 and proves we catch it, then cuts over with a strangler proxy and rolls back." |
| 2:45 to 4:15 | Postmortem 001 table, before/after numbers | "I broke it on purpose. Removing the DB network rule broke *nothing*: established connections survive policy changes. The outage only came with a DB restart. Requests hung 5 s; I fixed the timeouts and re-drilled: 2 s. The drill also caught a Helm 4 rollback trap and four bugs in my own triage tool." |
| 4:15 to 5:00 | `log_analyzer.py` output; ADR 0005 guardrails table | "Triage starts deterministic: findings with runbook links. Optionally Claude drafts the incident write-up, through a read-only, round-capped agent that only sees redacted aggregates and is always labelled a draft." |

## 15-minute live demo (laptop only)

1. **App and contract (2 min).** Open `localhost:18080/docs`. Schedule a sortie on an NMC aircraft
   and show the `409` with `rule` and `request_id`. Show the JSON log line with the same ID.
2. **Platform policies (3 min).**
   ```bash
   kubectl get ns sortie-tracker --show-labels                 # PSS restricted, gateway opt-in
   kubectl -n sortie-tracker get networkpolicy sortie-tracker -o yaml | head -40
   kubectl -n sortie-tracker exec deploy/sortie-tracker -c api -- \
     python -c "import urllib.request; urllib.request.urlopen('http://example.com', timeout=3)"  # times out
   ```
3. **Chaos + triage (6 min).**
   ```bash
   scripts/chaos.sh traffic
   scripts/chaos.sh db-outage inject      # watch: kubectl -n sortie-tracker get pods -w
   python scripts/log_analyzer.py --kubectl --since 5m
   scripts/chaos.sh db-outage recover
   ```
   Point out: pods go `0/1` but never restart (liveness vs readiness), 503s arrive in about 2 s,
   and the top finding links `db-connectivity.md`.
4. **Safe rollout (2 min).** `scripts/chaos.sh bad-image inject`: the new pod is stuck, the old
   pods keep serving (`maxUnavailable: 0`). Then `recover`.
5. **Questions (2 min).** Keep `docs/architecture.md` open for the diagrams.

## If something goes wrong live

- Gateway unreachable: `kubectl -n envoy-gateway-system get gateway,pods`. Port-forward the envoy
  service (see `deploy/local/kind-e2e.sh`).
- Pods stuck after a drill: `scripts/chaos.sh recover-all` (Helm rollback to current, `--force-conflicts`).
- Worst case: `make k8s-local-down && make k8s-local-e2e` rebuilds everything in about 8 minutes.
