#!/usr/bin/env bash
# Installs the shared platform layer on the current kube-context:
#   1. Namespaces with Pod Security Admission levels
#   2. Envoy Gateway (+ Gateway API CRDs) and the shared hangar-gateway
#   3. kube-prometheus-stack (Prometheus, Alertmanager, Grafana)
#
# Idempotent: re-running upgrades in place. Versions are pinned; bump them
# deliberately and re-run.
#
# Usage: deploy/platform/install-addons.sh            (after `make aks-credentials`)
#        SKIP_MONITORING=true deploy/platform/install-addons.sh
set -Eeuo pipefail

ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.9.2}"
KUBE_PROMETHEUS_STACK_VERSION="${KUBE_PROMETHEUS_STACK_VERSION:-91.9.0}"
SKIP_MONITORING="${SKIP_MONITORING:-false}"
# Clusters without a cloud load balancer (kind) never reach Programmed.
GATEWAY_READY_CONDITION="${GATEWAY_READY_CONDITION:-Programmed}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;34m[platform]\033[0m %s\n' "$*" >&2; }

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null || { echo "missing: $cmd" >&2; exit 1; }
done

log "Target cluster: $(kubectl config current-context)"

log "Applying namespaces"
kubectl apply -f "${HERE}/namespaces.yaml"

log "Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION}"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "$ENVOY_GATEWAY_VERSION" \
  --namespace envoy-gateway-system \
  --values "${HERE}/values/envoy-gateway.yaml" \
  --wait --timeout 10m

kubectl -n envoy-gateway-system wait deployment/envoy-gateway \
  --for=condition=Available --timeout=5m

log "Applying shared Gateway"
kubectl apply -f "${HERE}/gateway.yaml"
kubectl -n envoy-gateway-system wait gateway/hangar-gateway \
  --for="condition=${GATEWAY_READY_CONDITION}" --timeout=10m

if [[ "$SKIP_MONITORING" != "true" ]]; then
  # Generate the Grafana admin password once; never stored in git or values.
  if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    log "Creating Grafana admin secret"
    kubectl -n monitoring create secret generic grafana-admin \
      --from-literal=admin-user=admin \
      --from-literal=admin-password="$(openssl rand -base64 24)"
  fi

  log "Installing kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_VERSION}"
  helm upgrade --install kube-prometheus-stack kube-prometheus-stack \
    --repo https://prometheus-community.github.io/helm-charts \
    --version "$KUBE_PROMETHEUS_STACK_VERSION" \
    --namespace monitoring \
    --values "${HERE}/values/kube-prometheus-stack.yaml" \
    --wait --timeout 15m
fi

GATEWAY_IP="$(kubectl -n envoy-gateway-system get gateway hangar-gateway \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
log "Platform ready. Gateway address: ${GATEWAY_IP:-<pending>}"
log "Grafana: kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
log "         password: kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
