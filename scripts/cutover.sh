#!/usr/bin/env bash
# Legacy VM -> AKS cutover for Sortie Tracker, end to end.
#
#   scripts/cutover.sh migrate <env>    freeze, migrate, verify, switch traffic
#   scripts/cutover.sh rollback <env>   send traffic back to the legacy service
#
# Steps (migrate):
#   1. Preflight: tools, Azure session, kube-context, new platform healthy
#   2. Read target DB credentials from Key Vault (never written to disk)
#   3. Scale the AKS app to 0 so nothing writes to the target during the copy
#   4. ansible migrate.yml: freeze legacy writes, copy, checksum-verify (report)
#   5. Scale AKS back up; verify it serves exactly the migrated row counts
#   6. ansible cutover.yml: legacy endpoint proxies to the AKS gateway
#
# A failure before step 6 leaves (or restores) the legacy service in charge.
# See docs/runbooks/migration.md for the full procedure and go/no-go criteria.
set -Eeuo pipefail

ACTION="${1:?usage: cutover.sh <migrate|rollback> <dev|prod>}"
ENV="${2:?usage: cutover.sh <migrate|rollback> <dev|prod>}"
ASSUME_YES="${ASSUME_YES:-false}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
LIVE="${REPO_ROOT}/infra/live/${ENV}"
NS=sortie-tracker
ORIGINAL_REPLICAS=""

log()  { printf '\033[1;34m[cutover %s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[cutover] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  [[ "$ASSUME_YES" == "true" ]] && return 0
  read -r -p "$1 [type 'yes' to continue] " reply
  [[ "$reply" == "yes" ]] || die "aborted by operator"
}

tg_output() { terragrunt --working-dir "${LIVE}/$1" output -raw "$2" --log-level error; }

playbook() {
  (cd "$ANSIBLE_DIR" && ansible-playbook "playbooks/$1" -l "env_${ENV}" "${@:2}")
}

restore_aks_replicas() {
  if [[ -n "$ORIGINAL_REPLICAS" ]]; then
    log "Restoring AKS app to ${ORIGINAL_REPLICAS} replicas"
    kubectl -n "$NS" scale deploy/sortie-tracker --replicas="$ORIGINAL_REPLICAS"
  fi
}

preflight() {
  for cmd in az kubectl terragrunt ansible-playbook curl jq; do
    command -v "$cmd" >/dev/null || die "missing tool: ${cmd}"
  done
  [[ -d "$LIVE" ]] || die "unknown environment: ${ENV}"
  az account show -o none 2>/dev/null || die "run az login first"
  [[ "$(kubectl config current-context)" == "aks-hangar-${ENV}" ]] \
    || die "kube-context must be aks-hangar-${ENV} (make aks-credentials ENV=${ENV})"

  GATEWAY_IP="$(kubectl -n envoy-gateway-system get gateway hangar-gateway \
    -o jsonpath='{.status.addresses[0].value}')"
  [[ -n "$GATEWAY_IP" ]] || die "gateway has no address"
  curl -fsS --max-time 10 "http://${GATEWAY_IP}/healthz" >/dev/null \
    || die "new platform not healthy at http://${GATEWAY_IP}"
  log "New platform healthy at http://${GATEWAY_IP}"
}

migrate() {
  preflight

  log "Reading target credentials from Key Vault"
  local kv
  kv="$(tg_output keyvault name)"
  secret() { az keyvault secret show --vault-name "$kv" --name "$1" --query value -o tsv; }
  export MIGRATION_TARGET_HOST MIGRATION_TARGET_DATABASE MIGRATION_TARGET_USER MIGRATION_TARGET_PASSWORD
  MIGRATION_TARGET_HOST="$(secret postgres-host)"
  MIGRATION_TARGET_DATABASE="$(secret postgres-database)"
  MIGRATION_TARGET_USER="$(secret postgres-admin-username)"
  MIGRATION_TARGET_PASSWORD="$(secret postgres-admin-password)"

  log "Plan: freeze legacy writes -> copy to ${MIGRATION_TARGET_HOST} -> verify -> switch traffic"
  confirm "Begin maintenance window for ${ENV}?"

  ORIGINAL_REPLICAS="$(kubectl -n "$NS" get deploy/sortie-tracker -o jsonpath='{.spec.replicas}')"
  trap restore_aks_replicas EXIT
  log "Scaling AKS app to 0 (was ${ORIGINAL_REPLICAS}) to keep the target quiet"
  kubectl -n "$NS" scale deploy/sortie-tracker --replicas=0
  kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/name=sortie-tracker --timeout=2m || true

  log "Running migration (legacy writes frozen; restored automatically on failure)"
  local marker report expected actual
  marker="$(mktemp)"
  playbook migrate.yml

  report="$(find "${REPO_ROOT}/reports/migration" -name report.json -newer "$marker" | head -n1)"
  rm -f "$marker"
  [[ -n "$report" ]] || die "no migration report produced"
  [[ "$(jq -r .result "$report")" == "PASS" ]] || die "migration report is not PASS: ${report}"
  expected="$(jq '[.tables[] | select(.name=="aircraft") | .source_rows] | first' "$report")"

  restore_aks_replicas
  trap - EXIT
  kubectl -n "$NS" rollout status deploy/sortie-tracker --timeout=5m

  actual="$(curl -fsS "http://${GATEWAY_IP}/api/v1/readiness" | jq .total_aircraft)"
  [[ "$actual" == "$expected" ]] || die "AKS reports ${actual} aircraft, migrated ${expected}"
  log "AKS serves the migrated data (${actual} aircraft)"

  confirm "Switch legacy clients to AKS now?"
  playbook cutover.yml -e "legacy_cutover_upstream_url=http://${GATEWAY_IP}"
  log "Cutover complete. Report: ${report}"
  log "Rollback if needed: scripts/cutover.sh rollback ${ENV}"
}

rollback() {
  log "Rolling back ${ENV}: legacy service will answer again"
  log "Writes made on AKS since cutover are NOT copied back (see runbook: reconciliation)"
  confirm "Roll back ${ENV}?"
  playbook rollback.yml
  log "Rollback complete"
}

case "$ACTION" in
  migrate) migrate ;;
  rollback) rollback ;;
  *) die "unknown action: ${ACTION}" ;;
esac
