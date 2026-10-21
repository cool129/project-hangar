#!/usr/bin/env bash
# Deploys Sortie Tracker to an environment's AKS cluster.
#
# Every environment-specific identifier (registry, Key Vault, workload identity
# client ID, tenant) is read from Terraform outputs at deploy time, so nothing
# drifts between infrastructure and application config.
#
# Usage: deploy/deploy.sh <dev|prod> <image-tag> [extra helm args...]
#   e.g. deploy/deploy.sh dev 207e7a8
#        deploy/deploy.sh prod 207e7a8 --set image.digest=sha256:...
#
# Requires: kubectl context for the target cluster (make aks-credentials),
# terragrunt access to remote state (az login or CI OIDC).
set -Eeuo pipefail

ENV="${1:?usage: deploy.sh <dev|prod> <image-tag> [helm args...]}"
TAG="${2:?usage: deploy.sh <dev|prod> <image-tag> [helm args...]}"
shift 2

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE="${REPO_ROOT}/infra/live/${ENV}"
CHART="${REPO_ROOT}/deploy/helm/sortie-tracker"
NAMESPACE="sortie-tracker"
RELEASE="sortie-tracker"

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*" >&2; }

[[ -d "$LIVE" ]] || { echo "Unknown environment: ${ENV}" >&2; exit 1; }

tg_output() {
  terragrunt --working-dir "${LIVE}/$1" output -raw "$2" --log-level error
}

log "Reading Terraform outputs for ${ENV}"
ACR_LOGIN_SERVER="$(tg_output acr login_server)"
KEY_VAULT_NAME="$(tg_output keyvault name)"
TENANT_ID="$(tg_output keyvault tenant_id)"
CLIENT_ID="$(tg_output app-identity client_id)"

EXPECTED_CONTEXT="aks-hangar-${ENV}"
CURRENT_CONTEXT="$(kubectl config current-context)"
if [[ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]]; then
  echo "kube-context is '${CURRENT_CONTEXT}', expected '${EXPECTED_CONTEXT}'. Run: make aks-credentials ENV=${ENV}" >&2
  exit 1
fi

log "Deploying ${ACR_LOGIN_SERVER}/sortie-tracker:${TAG} to ${ENV}"
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --values "${CHART}/values-${ENV}.yaml" \
  --set image.repository="${ACR_LOGIN_SERVER}/sortie-tracker" \
  --set image.tag="$TAG" \
  --set secrets.keyVaultName="$KEY_VAULT_NAME" \
  --set workloadIdentity.clientId="$CLIENT_ID" \
  --set workloadIdentity.tenantId="$TENANT_ID" \
  --rollback-on-failure \
  --timeout 10m \
  "$@"

kubectl -n "$NAMESPACE" rollout status "deployment/${RELEASE}" --timeout=5m

GATEWAY_IP="$(kubectl -n envoy-gateway-system get gateway hangar-gateway \
  -o jsonpath='{.status.addresses[0].value}')"
log "Smoke test via gateway ${GATEWAY_IP}"
for path in /healthz /api/v1/readiness; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${GATEWAY_IP}${path}")"
  log "  GET ${path} -> ${code}"
  [[ "$code" == "200" ]] || { echo "Smoke test failed for ${path}" >&2; exit 1; }
done
# /metrics must NOT be reachable from outside the cluster.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${GATEWAY_IP}/metrics")"
log "  GET /metrics -> ${code} (expect 404)"
[[ "$code" == "404" ]] || { echo "/metrics is publicly exposed!" >&2; exit 1; }

log "Deployed ${TAG} to ${ENV}: http://${GATEWAY_IP}/docs"
