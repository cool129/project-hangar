#!/usr/bin/env bash
# Creates the Azure Storage backend that holds Terraform/Terragrunt remote state.
#
# Security posture:
#   - Shared-key (access key) auth disabled: Terraform must use Entra ID (use_azuread_auth).
#   - No public blob access, TLS 1.2 minimum, HTTPS only.
#   - Blob versioning + 30-day soft delete so a corrupted state file can be recovered.
#   - CanNotDelete lock on the resource group.
#
# Idempotent: safe to re-run.
#
# Overridable env vars: LOCATION, STATE_RG, STATE_SA, STATE_CONTAINER
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd az sha256sum
require_az_login

LOCATION="${LOCATION:-eastus2}"
STATE_RG="${STATE_RG:-rg-hangar-tfstate}"
STATE_CONTAINER="${STATE_CONTAINER:-tfstate}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

# Storage account names are globally unique (3-24 lowercase alphanumerics).
# Derive a stable suffix from the subscription so re-runs hit the same account.
SUFFIX="$(printf '%s' "$SUBSCRIPTION_ID" | sha256sum | cut -c1-8)"
STATE_SA="${STATE_SA:-sthangartf${SUFFIX}}"

TAGS=(project=hangar purpose=tfstate managed-by=bootstrap)

log "Subscription: $(az account show --query name -o tsv) (${SUBSCRIPTION_ID})"
log "State backend: ${STATE_RG}/${STATE_SA}/${STATE_CONTAINER} in ${LOCATION}"

az group create --name "$STATE_RG" --location "$LOCATION" --tags "${TAGS[@]}" -o none

if az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" -o none 2>/dev/null; then
  log "Storage account ${STATE_SA} already exists"
else
  log "Creating storage account ${STATE_SA}"
  az storage account create \
    --name "$STATE_SA" \
    --resource-group "$STATE_RG" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --https-only true \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    --tags "${TAGS[@]}" \
    -o none
fi

log "Enabling blob versioning and soft delete"
az storage account blob-service-properties update \
  --account-name "$STATE_SA" \
  --resource-group "$STATE_RG" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30 \
  -o none

# With shared keys disabled, the operator needs a data-plane role to manage state.
SA_ID="$(az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --query id -o tsv)"
read -r PRINCIPAL_ID PRINCIPAL_TYPE < <(current_principal)
assign_role "$PRINCIPAL_ID" "$PRINCIPAL_TYPE" "Storage Blob Data Contributor" "$SA_ID"

# New role assignments can take a minute or two to propagate.
for attempt in $(seq 1 12); do
  if az storage container create \
      --name "$STATE_CONTAINER" \
      --account-name "$STATE_SA" \
      --auth-mode login -o none 2>/dev/null; then
    log "Container ${STATE_CONTAINER} ready"
    break
  fi
  [[ "$attempt" -eq 12 ]] && die "Could not create container (RBAC not propagated after ~3 min). Re-run shortly."
  log "Waiting for RBAC propagation (attempt ${attempt}/12)..."
  sleep 15
done

az lock create \
  --name lock-hangar-tfstate \
  --lock-type CanNotDelete \
  --resource-group "$STATE_RG" \
  --notes "Protects Terraform remote state. Remove deliberately before teardown." \
  -o none

upsert_env AZURE_SUBSCRIPTION_ID "$SUBSCRIPTION_ID"
upsert_env AZURE_TENANT_ID "$TENANT_ID"
upsert_env AZURE_LOCATION "$LOCATION"
upsert_env TF_STATE_RG "$STATE_RG"
upsert_env TF_STATE_SA "$STATE_SA"
upsert_env TF_STATE_CONTAINER "$STATE_CONTAINER"

log "Done. Settings written to ${HANGAR_ENV_FILE#"${REPO_ROOT}"/}"
