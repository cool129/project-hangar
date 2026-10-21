#!/usr/bin/env bash
# Run one chaos drill end to end on the local kind cluster and keep the evidence:
#   steady traffic -> inject -> hold -> recover -> settle -> log_analyzer report
#
# Usage: deploy/local/chaos-drill.sh <scenario> [hold-seconds]
#   e.g. deploy/local/chaos-drill.sh db-outage 90
# Prereq: the kind cluster from deploy/local/kind-e2e.sh (KEEP_CLUSTER=true).
# Output: reports/drills/<UTC timestamp>-<scenario>/{report.txt,report.json,logs.jsonl}
set -Eeuo pipefail

SCENARIO="${1:?usage: chaos-drill.sh <scenario> [hold-seconds]}"
HOLD="${2:-90}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${REPO_ROOT}/reports/drills/$(date -u +%Y%m%dT%H%M%SZ)-${SCENARIO}"
CHAOS="${REPO_ROOT}/scripts/chaos.sh"
PY="${PYTHON:-python3}"

log() { printf '\033[1;34m[drill]\033[0m %s\n' "$*" >&2; }

kubectl config use-context kind-hangar >/dev/null
mkdir -p "$OUT"

log "Baseline: steady traffic for 60s"
TRAFFIC_SECONDS=$((HOLD + 240)) bash "$CHAOS" traffic
sleep 60

log "Inject ${SCENARIO}, hold ${HOLD}s"
bash "$CHAOS" "$SCENARIO" inject
sleep "$HOLD"
bash "$CHAOS" "$SCENARIO" status 2>/dev/null | tail -n 20 > "${OUT}/state-during.txt" || true
kubectl -n sortie-tracker get pods -o wide > "${OUT}/pods-during.txt"

log "Recover ${SCENARIO}"
bash "$CHAOS" "$SCENARIO" recover
log "Settle 60s"
sleep 60

log "Analyze"
since="$((HOLD + 200))s"
set +e
"$PY" "${REPO_ROOT}/scripts/log_analyzer.py" --kubectl --since "$since" \
  --save-logs "${OUT}/logs.jsonl" > "${OUT}/report.txt"
rc=$?
"$PY" "${REPO_ROOT}/scripts/log_analyzer.py" --file "${OUT}/logs.jsonl" --json > "${OUT}/report.json"
set -e
kubectl -n envoy-gateway-system delete pod chaos-traffic --ignore-not-found >/dev/null

cat "${OUT}/report.txt"
log "Evidence saved to ${OUT} (analyzer exit ${rc}: 2 = critical finding)"
