#!/usr/bin/env bash
# Lets GitHub Actions authenticate to Azure with OpenID Connect (workload identity
# federation). No client secret is ever created, stored, or rotated.
#
# Creates:
#   - Entra ID app registration + service principal (sp-hangar-github)
#   - Federated credentials trusting this repo's main branch, pull requests,
#     and the dev/prod GitHub Environments
#   - Role assignments:
#       Contributor                                  subscription
#       Role Based Access Control Administrator      subscription, CONDITIONED so it
#                                                    can only grant the roles listed below
#       Storage Blob Data Contributor                Terraform state account
#
# Prerequisites: run bootstrap-tfstate.sh first; you need Owner (or User Access
# Administrator) on the subscription and permission to create app registrations.
#
# Overridable env vars:
#   GITHUB_REPO   owner/repo (default: parsed from the `origin` remote)
#   MAIN_BRANCH   default: main
#   ENVIRONMENTS  default: "dev prod"
#   APP_NAME      default: sp-hangar-github
#   SET_GH_VARS   true = also push repo variables + environments with the gh CLI
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd az git
require_az_login
load_env

# Written to .env.hangar by bootstrap-tfstate.sh.
for var in TF_STATE_RG TF_STATE_SA TF_STATE_CONTAINER; do
  [[ -n "${!var:-}" ]] || die "${var} not set. Run bootstrap/bootstrap-tfstate.sh first."
done

APP_NAME="${APP_NAME:-sp-hangar-github}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
ENVIRONMENTS="${ENVIRONMENTS:-dev prod}"
SET_GH_VARS="${SET_GH_VARS:-false}"

if [[ -z "${GITHUB_REPO:-}" ]]; then
  origin_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  if [[ "$origin_url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    GITHUB_REPO="${BASH_REMATCH[1]%.git}"
  else
    die "Set GITHUB_REPO=owner/repo or add a GitHub 'origin' remote."
  fi
fi

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
SUB_SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

log "GitHub repo: ${GITHUB_REPO} (branch: ${MAIN_BRANCH}, environments: ${ENVIRONMENTS})"

# --- App registration + service principal -----------------------------------
APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)"
if [[ -z "$APP_ID" ]]; then
  log "Creating app registration ${APP_NAME}"
  APP_ID="$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
else
  log "App registration ${APP_NAME} already exists (${APP_ID})"
fi

SP_OBJECT_ID="$(az ad sp list --filter "appId eq '${APP_ID}'" --query '[0].id' -o tsv)"
if [[ -z "$SP_OBJECT_ID" ]]; then
  log "Creating service principal"
  SP_OBJECT_ID="$(az ad sp create --id "$APP_ID" --query id -o tsv)"
fi

# --- Federated credentials ----------------------------------------------------
add_federated_credential() {
  local name="$1" subject="$2" count
  count="$(az ad app federated-credential list --id "$APP_ID" \
    --query "[?name=='${name}'] | length(@)" -o tsv)"
  if [[ "$count" != "0" ]]; then
    log "Federated credential ${name} already exists"
    return 0
  fi
  log "Adding federated credential ${name} -> ${subject}"
  az ad app federated-credential create --id "$APP_ID" -o none --parameters "$(cat <<EOF
{
  "name": "${name}",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "${subject}",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "GitHub Actions OIDC for ${GITHUB_REPO}"
}
EOF
)"
}

add_federated_credential "gh-branch-${MAIN_BRANCH}" "repo:${GITHUB_REPO}:ref:refs/heads/${MAIN_BRANCH}"
add_federated_credential "gh-pull-request"          "repo:${GITHUB_REPO}:pull_request"
for env in $ENVIRONMENTS; do
  add_federated_credential "gh-env-${env}" "repo:${GITHUB_REPO}:environment:${env}"
done

# --- Role assignments ---------------------------------------------------------
assign_role "$SP_OBJECT_ID" ServicePrincipal "Contributor" "$SUB_SCOPE"

# Terraform must create a few role assignments (AKS -> ACR pull, workload
# identity -> Key Vault, etc.). Instead of granting Owner, allow the pipeline to
# assign ONLY these roles. Extend this list (and re-create the assignment) if a
# later phase needs another role.
DELEGABLE_ROLES=(
  "AcrPull"
  "Key Vault Secrets User"
  "Key Vault Secrets Officer"
  "Network Contributor"
  "Monitoring Metrics Publisher"
  "Azure Kubernetes Service RBAC Cluster Admin"
  "Azure Kubernetes Service RBAC Writer"
)
role_guids=()
for role in "${DELEGABLE_ROLES[@]}"; do
  guid="$(az role definition list --name "$role" --query '[0].name' -o tsv)"
  [[ -n "$guid" ]] || die "Unknown role definition: ${role}"
  role_guids+=("$guid")
done
GUID_LIST="$(IFS=,; printf '%s' "${role_guids[*]}")"
GUID_LIST="${GUID_LIST//,/, }"

RBAC_CONDITION="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${GUID_LIST}})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${GUID_LIST}}))"

assign_role "$SP_OBJECT_ID" ServicePrincipal "Role Based Access Control Administrator" "$SUB_SCOPE" \
  --condition "$RBAC_CONDITION" --condition-version "2.0" \
  --description "Constrained delegation: may only assign Project HANGAR workload roles"

# shellcheck disable=SC2153  # TF_STATE_RG comes from .env.hangar
SA_ID="$(az storage account show --name "$TF_STATE_SA" --resource-group "$TF_STATE_RG" --query id -o tsv)"
assign_role "$SP_OBJECT_ID" ServicePrincipal "Storage Blob Data Contributor" "$SA_ID"

upsert_env AZURE_CLIENT_ID "$APP_ID"
upsert_env GITHUB_REPO "$GITHUB_REPO"

# --- GitHub repository variables (optional) ----------------------------------
# These are identifiers, not secrets: OIDC means there is nothing secret to store.
declare -A GH_VARS=(
  [AZURE_CLIENT_ID]="$APP_ID"
  [AZURE_TENANT_ID]="$TENANT_ID"
  [AZURE_SUBSCRIPTION_ID]="$SUBSCRIPTION_ID"
  [TF_STATE_RG]="$TF_STATE_RG"
  [TF_STATE_SA]="$TF_STATE_SA"
  [TF_STATE_CONTAINER]="$TF_STATE_CONTAINER"
)

if [[ "$SET_GH_VARS" == "true" ]]; then
  require_cmd gh
  for key in "${!GH_VARS[@]}"; do
    gh variable set "$key" --body "${GH_VARS[$key]}" --repo "$GITHUB_REPO"
  done
  for env in $ENVIRONMENTS; do
    gh api --method PUT "repos/${GITHUB_REPO}/environments/${env}" --silent
    log "GitHub Environment '${env}' ensured"
  done
  log "Repository variables set on ${GITHUB_REPO}"
else
  log "Set these as GitHub repository VARIABLES (Settings > Secrets and variables > Actions > Variables),"
  log "or re-run with SET_GH_VARS=true to do it with the gh CLI:"
  for key in "${!GH_VARS[@]}"; do
    printf '  %-22s %s\n' "$key" "${GH_VARS[$key]}"
  done
fi

warn "Add required reviewers to the 'prod' environment in GitHub (Settings > Environments > prod)."
log "Done."
