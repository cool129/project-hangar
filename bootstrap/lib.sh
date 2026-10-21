#!/usr/bin/env bash
# Shared helpers for bootstrap scripts. Source this file; do not execute it.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Non-secret, machine-local settings written by bootstrap and read by the Makefile.
HANGAR_ENV_FILE="${HANGAR_ENV_FILE:-${REPO_ROOT}/.env.hangar}"

log()  { printf '\033[1;34m[hangar]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[hangar] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[hangar] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
  done
}

require_az_login() {
  az account show --only-show-errors >/dev/null 2>&1 \
    || die "Not logged in to Azure. Run: az login (then: az account set -s <subscription>)"
}

# Load previously written settings, if any.
load_env() {
  if [[ -f "$HANGAR_ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$HANGAR_ENV_FILE"
    set +a
  fi
}

# Insert or replace KEY=VALUE in the env file (portable: no sed -i).
upsert_env() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if [[ -f "$HANGAR_ENV_FILE" ]]; then
    grep -v "^${key}=" "$HANGAR_ENV_FILE" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$HANGAR_ENV_FILE"
}

# Object ID and principal type of whoever is logged in to the Azure CLI.
current_principal() {
  local user_type user_name
  user_type="$(az account show --query user.type -o tsv)"
  user_name="$(az account show --query user.name -o tsv)"
  if [[ "$user_type" == "user" ]]; then
    printf '%s User\n' "$(az ad signed-in-user show --query id -o tsv)"
  else
    printf '%s ServicePrincipal\n' "$(az ad sp show --id "$user_name" --query id -o tsv)"
  fi
}

# assign_role <object-id> <principal-type> <role> <scope> [extra az args...]
# Idempotent: skips if the principal already holds the role at that scope.
assign_role() {
  local object_id="$1" principal_type="$2" role="$3" scope="$4"
  shift 4
  local existing
  existing="$(az role assignment list \
    --assignee "$object_id" --role "$role" --scope "$scope" \
    --query 'length(@)' -o tsv)"
  if [[ "$existing" != "0" ]]; then
    log "Role '${role}' already assigned at ${scope##*/}"
    return 0
  fi
  log "Assigning role '${role}' at ${scope##*/}"
  az role assignment create \
    --assignee-object-id "$object_id" \
    --assignee-principal-type "$principal_type" \
    --role "$role" --scope "$scope" "$@" -o none
}
