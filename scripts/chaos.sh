#!/usr/bin/env bash
# Chaos drills for Sortie Tracker: inject a realistic failure, watch detection
# and triage work, then recover. Each scenario names the alert that should
# fire and the runbook that covers it.
#
#   scripts/chaos.sh list
#   scripts/chaos.sh <scenario> inject|recover|status
#
# Safety: refuses to run against a context containing "prod" unless
# CHAOS_ALLOW_PROD=true. Every inject has a matching recover; `recover-all`
# reverts everything by re-applying the Helm release.
set -Eeuo pipefail

NS="${NS:-sortie-tracker}"
RELEASE="${RELEASE:-sortie-tracker}"
DEPLOY="deploy/${RELEASE}"
STATE_DIR="${STATE_DIR:-${TMPDIR:-/tmp}/hangar-chaos}"
mkdir -p "$STATE_DIR"

log()  { printf '\033[1;35m[chaos]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[chaos] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
hint() { printf '\033[0;36m  expect:\033[0m %s\n' "$*" >&2; }

guard() {
  local ctx
  ctx="$(kubectl config current-context)"
  if [[ "$ctx" == *prod* && "${CHAOS_ALLOW_PROD:-false}" != "true" ]]; then
    die "refusing to run chaos against '${ctx}' (set CHAOS_ALLOW_PROD=true to override)"
  fi
  kubectl -n "$NS" get "$DEPLOY" >/dev/null || die "${DEPLOY} not found in namespace ${NS}"
  log "context: ${ctx}, namespace: ${NS}"
}

# Generated traffic enters through the Envoy gateway, like real users, so the
# gateway's view (e.g. 503 "no healthy upstream") is part of every drill.
target_url() {
  local svc
  svc="$(kubectl -n envoy-gateway-system get svc \
    -l gateway.envoyproxy.io/owning-gateway-name=hangar-gateway -o jsonpath='{.items[0].metadata.name}')"
  echo "${CHAOS_TARGET_URL:-http://${svc}.envoy-gateway-system.svc.cluster.local}"
}

# Run a short-lived curl pod in the gateway namespace so drills work without a
# public IP (e.g. on kind). The pod meets the `restricted` Pod Security profile:
# chaos tooling should not itself violate the policies it exercises.
in_cluster_traffic() {
  local name="$1" script="$2"
  kubectl -n envoy-gateway-system delete pod "$name" --ignore-not-found >/dev/null
  kubectl -n envoy-gateway-system apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  labels:
    app.kubernetes.io/part-of: hangar-chaos
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: ${name}
      image: curlimages/curl:8.11.1
      command: ["sh", "-c"]
      args:
        - |
$(printf '%s\n' "$script" | sed 's/^/          /')
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
}

# Restart PostgreSQL so every pooled connection is dropped. On kind that is the
# local-db deployment; on Azure set CHAOS_PG_SERVER (and CHAOS_PG_RG), which is
# exactly what a planned maintenance restart does.
restart_database() {
  if kubectl get namespace local-db >/dev/null 2>&1; then
    kubectl -n local-db rollout restart statefulset/postgres
    kubectl -n local-db rollout status statefulset/postgres --timeout=3m
  elif [[ -n "${CHAOS_PG_SERVER:-}" ]]; then
    az postgres flexible-server restart -g "${CHAOS_PG_RG:?set CHAOS_PG_RG}" -n "$CHAOS_PG_SERVER"
  else
    log "WARNING: no database restart configured (set CHAOS_PG_SERVER/CHAOS_PG_RG);"
    log "         established connections survive the policy change, so impact stays latent."
  fi
}

# --- Scenarios -------------------------------------------------------------

bad_image_inject() {
  kubectl -n "$NS" set image "$DEPLOY" api="$(current_image | cut -d@ -f1 | cut -d: -f1):does-not-exist" migrate="$(current_image | cut -d@ -f1 | cut -d: -f1):does-not-exist"
  hint "new pod stuck in ImagePullBackOff; old pods keep serving (maxUnavailable: 0)"
  hint "alert SortieTrackerRolloutStuck after 15m; runbook pod-failures.md"
}
bad_image_recover() { kubectl -n "$NS" rollout undo "$DEPLOY" && kubectl -n "$NS" rollout status "$DEPLOY" --timeout=5m; }

oom_inject() {
  kubectl -n "$NS" patch "$DEPLOY" --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"40Mi"}]'
  hint "new pod OOMKilled -> CrashLoopBackOff; old pods keep serving"
  hint "alerts SortieTrackerCrashLooping / RolloutStuck; runbook pod-failures.md"
}
oom_recover() { kubectl -n "$NS" rollout undo "$DEPLOY" && kubectl -n "$NS" rollout status "$DEPLOY" --timeout=5m; }

db_outage_inject() {
  # Config drift: the PostgreSQL egress rule disappears from the NetworkPolicy.
  # Policies only gate NEW connections (conntrack keeps established flows), so
  # on its own the drift is latent: pooled connections keep working. A
  # database restart, which Azure does in every maintenance window, turns
  # it into an outage. The drill models that realistic sequence.
  local np="networkpolicy/${RELEASE}"
  kubectl -n "$NS" get "$np" -o jsonpath='{.spec.egress[1]}' > "${STATE_DIR}/db-egress-rule.json"
  grep -q 5432 "${STATE_DIR}/db-egress-rule.json" || die "egress[1] is not the PostgreSQL rule; refusing"
  kubectl -n "$NS" patch "$np" --type=json -p='[{"op":"remove","path":"/spec/egress/1"}]'
  log "egress rule removed (latent); restarting the database to drop pooled connections"
  restart_database
  hint "readiness fails within ~15s; no ready pods; gateway returns 503 with no upstream"
  hint "alerts SortieTrackerNoReadyPods, ErrorBudgetFastBurn; runbook db-connectivity.md"
}
db_outage_recover() {
  [[ -s "${STATE_DIR}/db-egress-rule.json" ]] || die "no saved egress rule; run recover-all"
  # Re-add only the rule we removed (a whole-object replace would fail on the
  # stale resourceVersion, which is optimistic concurrency doing its job).
  kubectl -n "$NS" patch "networkpolicy/${RELEASE}" --type=json \
    -p="[{\"op\":\"add\",\"path\":\"/spec/egress/1\",\"value\":$(cat "${STATE_DIR}/db-egress-rule.json")}]"
  kubectl -n "$NS" wait --for=condition=Ready pod -l "app.kubernetes.io/name=${RELEASE}" --timeout=3m
}

pod_kill_inject() {
  local pod
  pod="$(kubectl -n "$NS" get pod -l "app.kubernetes.io/name=${RELEASE}" -o name | head -n1)"
  kubectl -n "$NS" delete "$pod" --wait=false
  hint "ReplicaSet replaces ${pod} within seconds; the other replica keeps serving (PDB + spread)"
}
pod_kill_recover() { kubectl -n "$NS" rollout status "$DEPLOY" --timeout=3m; }

load_inject() {
  # 20 parallel clients for 5 minutes against the API: drives the HPA.
  in_cluster_traffic chaos-load "
    end=\$((\$(date +%s)+300));
    for i in \$(seq 20); do
      while [ \$(date +%s) -lt \$end ]; do curl -s -o /dev/null $(target_url)/api/v1/readiness; done &
    done; wait"
  hint "CPU rises; HPA scales up within ~1m (kubectl -n ${NS} get hpa -w)"
  hint "if latency degrades: alert SortieTrackerHighLatency; runbook high-latency.md"
}
load_recover() { kubectl -n envoy-gateway-system delete pod chaos-load --ignore-not-found; }

bad_client_inject() {
  # A misconfigured upstream system keeps trying to launch a grounded jet.
  local aircraft
  aircraft="$(kubectl -n "$NS" exec "$DEPLOY" -c api -- python -c \
    "import json,urllib.request;print(json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/v1/aircraft?status=NMC&limit=1'))[0]['id'])")"
  in_cluster_traffic chaos-bad-client "
    for i in \$(seq 600); do
      curl -s -o /dev/null -X POST $(target_url)/api/v1/sorties -H 'Content-Type: application/json' \
        -H \"X-Request-ID: chaos-bad-client-\$i\" \
        -d '{\"mission_number\":\"CHAOS-'\$i'\",\"aircraft_id\":${aircraft},\"mission_type\":\"TRAINING\",\"pilot_callsign\":\"GHOST 1\",\"scheduled_takeoff\":\"2026-11-01T09:00:00Z\"}';
      sleep 0.2;
    done"
  hint "HTTP 409 rule=aircraft_not_mission_capable floods; no outage"
  hint "alert SortieTrackerBusinessRuleSpike; runbook business-rule-spike.md"
}
bad_client_recover() { kubectl -n envoy-gateway-system delete pod chaos-bad-client --ignore-not-found; }

traffic_start() {
  # Steady ~4 req/s mix of reads and writes for TRAFFIC_SECONDS (default 600).
  in_cluster_traffic chaos-traffic "
    end=\$((\$(date +%s)+${TRAFFIC_SECONDS:-600})); i=0;
    while [ \$(date +%s) -lt \$end ]; do
      i=\$((i+1));
      curl -s -o /dev/null -H \"X-Request-ID: traffic-\$i\" $(target_url)/api/v1/aircraft?limit=5;
      curl -s -o /dev/null $(target_url)/api/v1/readiness;
      curl -s -o /dev/null $(target_url)/api/v1/sorties?status=SCHEDULED;
      sleep 0.7;
    done"
  log "background traffic running for ${TRAFFIC_SECONDS:-600}s (pod envoy-gateway-system/chaos-traffic)"
}

current_image() {
  kubectl -n "$NS" get "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}'
}

recover_all() {
  for p in chaos-load chaos-bad-client chaos-traffic; do
    kubectl -n envoy-gateway-system delete pod "$p" --ignore-not-found >/dev/null
  done
  # Helm owns the desired state. Rolling back to the *current* revision
  # re-applies it ("0" would mean the previous revision). Helm 4 applies
  # server-side, so fields changed by `kubectl patch` now belong to another
  # field manager and the rollback is refused unless conflicts are forced.
  local current
  current="$(helm -n "$NS" history "$RELEASE" --max 1 | awk 'NR==2 {print $1}')"
  helm -n "$NS" rollback "$RELEASE" "$current" --force-conflicts --wait --timeout 5m
}

status() {
  kubectl -n "$NS" get deploy,rs,pods,hpa -o wide
  echo
  kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -n 15
}

SCENARIOS="bad-image oom db-outage pod-kill load bad-client"

case "${1:-list}" in
  list)
    cat <<EOF
Scenarios (scripts/chaos.sh <scenario> inject|recover):
  bad-image   deploy an image tag that does not exist      -> rollout guard, RolloutStuck
  oom         drop the memory limit to 40Mi                -> OOMKilled, CrashLooping
  db-outage   cut PostgreSQL egress via NetworkPolicy       -> 503s, DatabaseErrors, fast burn
  pod-kill    delete a running pod                          -> self-healing, no user impact
  load        20 concurrent clients for 5 minutes           -> HPA scale-out, latency
  bad-client  misbehaving client launching an NMC aircraft  -> 409 flood, BusinessRuleSpike
Other: traffic (steady background load) | status | recover-all
EOF
    ;;
  status) guard; status ;;
  traffic) guard; traffic_start ;;
  recover-all) guard; recover_all ;;
  *)
    scenario="$1"; action="${2:-}"
    [[ " ${SCENARIOS} " == *" ${scenario} "* ]] || die "unknown scenario: ${scenario} (see: chaos.sh list)"
    [[ "$action" == "inject" || "$action" == "recover" ]] || die "action must be inject or recover"
    guard
    log "${scenario}: ${action}"
    date -u +%Y-%m-%dT%H:%M:%SZ > "${STATE_DIR}/${scenario}.${action}.at"
    "${scenario//-/_}_${action}"
    log "done. Triage: python scripts/log_analyzer.py --kubectl --since 15m"
    ;;
esac
