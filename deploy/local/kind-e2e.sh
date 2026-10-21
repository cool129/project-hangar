#!/usr/bin/env bash
# End-to-end test of the platform + chart on a local kind cluster, no Azure needed:
#   - platform namespaces with Pod Security Admission (app ns = restricted)
#   - Envoy Gateway + the shared Gateway from deploy/platform
#   - the Helm chart with 2 replicas racing migrations (advisory lock)
#   - NetworkPolicies enforced by kindnet
#   - traffic through the gateway; /metrics must be blocked at the edge
#
# Usage: deploy/local/kind-e2e.sh          (KEEP_CLUSTER=false to delete afterwards)
set -Eeuo pipefail

CLUSTER="${CLUSTER:-hangar}"
KEEP_CLUSTER="${KEEP_CLUSTER:-true}"
IMAGE="${IMAGE:-sortie-tracker:local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS=sortie-tracker
PF_PIDS=()

log()  { printf '\033[1;34m[e2e]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[e2e] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  if [[ "$KEEP_CLUSTER" != "true" ]]; then kind delete cluster --name "$CLUSTER"; fi
}
trap cleanup EXIT

for cmd in kind kubectl helm docker curl; do
  command -v "$cmd" >/dev/null || fail "missing tool: ${cmd}"
done

if ! kind get clusters | grep -qx "$CLUSTER"; then
  log "Creating kind cluster ${CLUSTER}"
  kind create cluster --name "$CLUSTER" --wait 2m
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

log "Loading ${IMAGE} into the cluster"
kind load docker-image "$IMAGE" --name "$CLUSTER"

log "Installing platform add-ons (monitoring skipped locally)"
SKIP_MONITORING=true GATEWAY_READY_CONDITION=Accepted \
  "${REPO_ROOT}/deploy/platform/install-addons.sh"

log "Starting throwaway PostgreSQL"
kubectl apply -f "${REPO_ROOT}/deploy/local/postgres.yaml"
kubectl -n local-db rollout status deploy/postgres --timeout=3m

# Same keys the Key Vault CSI driver would mount in Azure.
kubectl -n "$NS" create secret generic sortie-tracker-db \
  --from-literal=postgres-host=postgres.local-db.svc.cluster.local \
  --from-literal=postgres-database=sortie_tracker \
  --from-literal=postgres-admin-username=sortie \
  --from-literal=postgres-admin-password=local-dev-only \
  --dry-run=client -o yaml | kubectl apply -f -

log "Deploying chart"
helm upgrade --install sortie-tracker "${REPO_ROOT}/deploy/helm/sortie-tracker" \
  --namespace "$NS" \
  --values "${REPO_ROOT}/deploy/local/values-local.yaml" \
  --rollback-on-failure --timeout 5m
kubectl -n "$NS" rollout status deploy/sortie-tracker --timeout=3m

log "Checking both init containers migrated without conflict"
for pod in $(kubectl -n "$NS" get pods -l app.kubernetes.io/name=sortie-tracker -o name); do
  status="$(kubectl -n "$NS" get "$pod" -o jsonpath='{.status.initContainerStatuses[0].state.terminated.reason}')"
  [[ "$status" == "Completed" ]] || fail "${pod} migrate init container: ${status:-not terminated}"
done

log "Seeding data"
kubectl -n "$NS" exec deploy/sortie-tracker -c api -- sortie-tracker-seed --if-empty

ENVOY_SVC="$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=hangar-gateway -o jsonpath='{.items[0].metadata.name}')"
kubectl -n envoy-gateway-system port-forward "svc/${ENVOY_SVC}" 18081:80 >/dev/null 2>&1 &
PF_PIDS+=($!)
sleep 3

expect() {
  local path="$1" want="$2" got
  got="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:18081${path}")"
  [[ "$got" == "$want" ]] || fail "GET ${path} via gateway: got ${got}, want ${want}"
  log "  GET ${path} via gateway -> ${got}"
}
log "Testing through the gateway"
expect /healthz 200
expect /api/v1/readiness 200
expect /docs 200
expect /metrics 404
expect /readyz 404

log "Checking request ID propagates gateway -> app"
rid="e2e-$(date +%s)"
curl -s -o /dev/null -H "X-Request-ID: ${rid}" "http://127.0.0.1:18081/api/v1/aircraft?limit=1"
sleep 1
kubectl -n "$NS" logs -l app.kubernetes.io/name=sortie-tracker -c api --tail=200 | grep -q "\"request_id\": \"${rid}\"" \
  || fail "request ID ${rid} not found in app logs"
log "  ${rid} found in app logs"

log "Checking NetworkPolicy blocks unexpected egress"
if kubectl -n "$NS" exec deploy/sortie-tracker -c api -- \
  python -c "import urllib.request; urllib.request.urlopen('http://example.com', timeout=5)" 2>/dev/null; then
  fail "pod reached the internet; egress policy not enforced"
fi
log "  outbound internet blocked as expected"

log "All end-to-end checks passed"
