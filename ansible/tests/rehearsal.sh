#!/usr/bin/env bash
# Full migration rehearsal with local stand-ins for every Azure component.
#
#   1. Converge the legacy host (hardening + legacy app + node exporter) over SSH
#   2. Re-run and require zero changes (idempotence)
#   3. Migrate legacy PostgreSQL -> "Azure" PostgreSQL; require a PASS report
#   4. Re-run against the now non-empty target: must refuse, and must restore
#      the frozen legacy service
#   5. Tamper with one target row: validation must FAIL; repair: must PASS
#   6. Start the new platform; it must serve the migrated row counts
#   7. Cut over (legacy port proxies to the platform), then roll back
#   8. ansible-lint (production profile)
#
# Usage: ansible/tests/rehearsal.sh      (KEEP=true leaves the sandbox running)
# Needs: docker, ssh-keygen, the sortie-tracker:local image (make app-build).
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${HERE}/.work"
OUT="${HERE}/.out"
KEEP="${KEEP:-false}"
COMPOSE=(docker compose -f "${HERE}/compose.yml")
LEGACY=172.29.250.10
PLATFORM=172.29.250.30
TARGET_PASSWORD='Rehearsal#Pass%9+x'

step() { printf '\n\033[1;35m=== %s\033[0m\n' "$*" >&2; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*" >&2; }
fail() { printf '\033[1;31m  ✘ %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ "$KEEP" != "true" ]]; then "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

ctl() { "${COMPOSE[@]}" exec -T controller bash -c "$*"; }
PB="ansible-playbook -i tests/inventory.yml -e local_credentials_dir=/tmp/hangar-credentials"
target_env="MIGRATION_TARGET_HOST=172.29.250.20 MIGRATION_TARGET_USER=hangaradmin \
MIGRATION_TARGET_PASSWORD='${TARGET_PASSWORD}' MIGRATION_TARGET_SSLMODE=disable"
migrate() { ctl "${target_env} ${PB} playbooks/migrate.yml -e migration_local_report_dir=/out/reports $*"; }
# Reports and API responses are read inside the controller (jq), not on the host.
report_field() { ctl "jq -r '$1' \"\$(ls -t /out/reports/*/report.json | head -n1)\""; }
api_field() { ctl "curl -fsS $1 | jq -r '$2'"; }
psql_target() { "${COMPOSE[@]}" exec -T azurepg psql -U hangaradmin -d sortie_tracker -tAc "$1"; }

docker image inspect sortie-tracker:local >/dev/null 2>&1 || fail "missing image sortie-tracker:local (make app-build)"
mkdir -p "$WORK" "$OUT"
rm -rf "${OUT:?}/reports"
[[ -f "${WORK}/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C rehearsal -f "${WORK}/id_ed25519"
export REHEARSAL_SSH_PUBKEY
REHEARSAL_SSH_PUBKEY="$(cat "${WORK}/id_ed25519.pub")"

step "Starting sandbox"
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d --build legacy azurepg controller
ctl "install -d -m 700 /root/.ssh && install -m 600 /work/id_ed25519 /root/.ssh/id_ed25519"
ctl "for i in \$(seq 60); do ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new hangaradmin@${LEGACY} true 2>/dev/null && exit 0; sleep 2; done; exit 1" \
  || fail "legacy host never accepted SSH"
ok "legacy host reachable over SSH"

step "1. Converge legacy host"
ctl "${PB} playbooks/site.yml"
[[ "$(api_field "http://${LEGACY}:8000/api/v1/readiness" .total_aircraft)" == "24" ]] \
  || fail "legacy API does not report 24 aircraft"
ok "legacy Sortie Tracker serving 24 aircraft from its local PostgreSQL"

step "2. Idempotence"
ctl "ANSIBLE_NOCOLOR=1 ANSIBLE_FORCE_COLOR=0 ${PB} playbooks/site.yml" | tee "${WORK}/second-run.log"
grep -Eq "legacy +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0" "${WORK}/second-run.log" \
  || fail "second run reported changes (not idempotent)"
ok "second converge: changed=0"
ctl "ssh -o BatchMode=yes hangaradmin@${LEGACY} 'sudo sshd -T' | grep -E '^(passwordauthentication|permitrootlogin|ciphers) '"
ctl "ssh -o BatchMode=yes hangaradmin@${LEGACY} 'sudo ufw status verbose' | head -n 12"

step "3. Migrate legacy -> managed PostgreSQL"
"${COMPOSE[@]}" up -d --wait platform   # initialises target schema like the AKS init container
"${COMPOSE[@]}" stop platform           # cutover.sh scales AKS to 0 during the copy
migrate
[[ "$(report_field .result)" == "PASS" ]] || fail "migration report not PASS"
ok "migration PASS: $(report_field '[.tables[] | "\(.name)=\(.target_rows)"] | join(", ")')"
# shellcheck disable=SC2016  # expanded inside the controller, not here
ctl 'cat "$(ls -t /out/reports/*/report.md | head -n1)"'

step "4. Re-running against a non-empty target must refuse"
if migrate >"${WORK}/rerun.log" 2>&1; then fail "second migration should have been refused"; fi
grep -q "target tables not empty" "${WORK}/rerun.log" || fail "refused for the wrong reason"
[[ "$(api_field "http://${LEGACY}:8000/healthz" .environment)" == "legacy" ]] \
  || fail "legacy service was not restored after the failed run"
ok "refused to merge into a populated target; legacy service restored by rescue"

step "5. Tamper detection"
original="$(psql_target "SELECT pilot_callsign FROM sorties WHERE id = 1")"
psql_target "UPDATE sorties SET pilot_callsign = 'TAMPERED' WHERE id = 1" >/dev/null
if migrate -e migration_validate_only=true >"${WORK}/tamper.log" 2>&1; then fail "tampering went undetected"; fi
[[ "$(report_field '.tables[] | select(.name=="sorties") | .match')" == "false" ]] \
  || fail "sorties table not flagged"
ok "one changed row in 300 detected (sorties checksum mismatch)"
psql_target "UPDATE sorties SET pilot_callsign = '${original}' WHERE id = 1" >/dev/null
migrate -e migration_validate_only=true >/dev/null
[[ "$(report_field .result)" == "PASS" ]] || fail "repaired target does not validate"
ok "after repair: PASS"

step "6. New platform serves migrated data"
"${COMPOSE[@]}" up -d --wait platform
[[ "$(api_field "http://${PLATFORM}:8000/api/v1/readiness" .total_aircraft)" == "24" ]] \
  || fail "platform does not serve the migrated fleet"
ok "platform serves 24 aircraft from the managed database"

step "7. Cutover and rollback"
ctl "${PB} playbooks/cutover.yml -e legacy_cutover_upstream_url=http://${PLATFORM}:8000"
[[ "$(api_field "http://${LEGACY}:8000/healthz" .environment)" == "rehearsal-aks" ]] \
  || fail "legacy endpoint is not proxying to the platform"
ctl "curl -fsS -D - -o /dev/null http://${LEGACY}:8000/healthz" | grep -qi "x-served-by: legacy-cutover-proxy" \
  || fail "proxy header missing"
ok "legacy clients now served by the new platform (strangler proxy)"
ctl "${PB} playbooks/rollback.yml"
[[ "$(api_field "http://${LEGACY}:8000/healthz" .environment)" == "legacy" ]] \
  || fail "rollback did not restore the legacy service"
ok "rollback restored the legacy service"

step "8. ansible-lint (production profile)"
ctl "rm -rf /tmp/lint && cp -r /repo/ansible /tmp/lint && cd /tmp/lint && ansible-lint"
ok "ansible-lint clean"

step "Rehearsal passed. Reports: ${OUT}/reports"
