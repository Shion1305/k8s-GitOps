#!/usr/bin/env bash
# Autoscaling lifecycle timeline: drive a scale-from-zero model through its full
# replica lifecycle and record, with timestamps, every replica-count transition:
#
#   0 (idle) → [light load] → 1 → [heavy load] → 2 → [stop load] → 1 → 0
#
# A background poller logs ready-replica transitions; a foreground load driver
# runs three phases (light, heavy, idle). Requires minReplicas:0, kubectl, and a
# port-forward to KubeAI. Cards = 2, so max ready replicas is 2.
#
# Usage:
#   kubectl -n scalable-llm port-forward svc/kubeai 8000:80 &
#   ./scalable-llm/bench/lifecycle_timeline.sh
set -uo pipefail

NS=scalable-llm
MODEL=tt-llama
BASE=${BASE:-http://localhost:8000/openai/v1}
LIGHT_CONC=${LIGHT_CONC:-2}      # drives ~1 replica (in-flight ~2 vs targetRequests 4)
HEAVY_CONC=${HEAVY_CONC:-24}     # drives 2 replicas (in-flight >> targetRequests)
LIGHT_SECS=${LIGHT_SECS:-180}
HEAVY_SECS=${HEAVY_SECS:-240}
IDLE_SECS=${IDLE_SECS:-900}      # watch scale-down; KubeAI uses a 10m moving avg

min=$(kubectl get model -n "$NS" "$MODEL" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
[ "${min:-1}" = "0" ] || { echo "ERROR: minReplicas is ${min:-?}, need 0" >&2; exit 1; }

T0=$(date +%s.%N)
rel() { awk "BEGIN{printf \"%6.1f\", $(date +%s.%N) - $T0}"; }
log() { echo "[$(rel)s] $*"; }

echo "=== autoscaling lifecycle for $MODEL (min=0, max=2) ==="
echo "phases: idle→light(${LIGHT_SECS}s,c=$LIGHT_CONC)→heavy(${HEAVY_SECS}s,c=$HEAVY_CONC)→idle(${IDLE_SECS}s)"
log "start: ready replicas = $(kubectl get model -n $NS $MODEL -o jsonpath='{.status.replicas.ready}' 2>/dev/null || echo 0)"

# Background poller: emit every change in ready-replica count + desired target.
(
  prev=""
  while :; do
    ready=$(kubectl get model -n "$NS" "$MODEL" -o jsonpath='{.status.replicas.ready}' 2>/dev/null); ready=${ready:-0}
    all=$(kubectl get model -n "$NS" "$MODEL" -o jsonpath='{.status.replicas.all}' 2>/dev/null); all=${all:-0}
    cur="ready=$ready all=$all"
    if [ "$cur" != "$prev" ]; then log "REPLICAS $cur"; prev="$cur"; fi
    sleep 2
  done
) &
POLL=$!
trap 'kill $POLL 2>/dev/null' EXIT

# One streaming request (keeps a worker busy ~5s of decode).
fire() {
  curl -s -m 120 "$BASE/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"'"$MODEL"'","messages":[{"role":"user","content":"Write two sentences about Kubernetes."}],"max_tokens":128,"stream":true}' \
    >/dev/null 2>&1
}
# Sustained load at concurrency C for D seconds.
load() {
  local C=$1
  local D=$2
  local end=$(( $(date +%s) + D ))
  while [ "$(date +%s)" -lt "$end" ]; do
    for _ in $(seq 1 "$C"); do fire & done
    wait
  done
}

log "PHASE: LIGHT load (expect 0→1)"
load "$LIGHT_CONC" "$LIGHT_SECS"
log "PHASE: HEAVY load (expect 1→2)"
load "$HEAVY_CONC" "$HEAVY_SECS"
log "PHASE: IDLE (expect 2→1→0; KubeAI 10m moving avg, so slow)"
end=$(( $(date +%s) + IDLE_SECS ))
while [ "$(date +%s)" -lt "$end" ]; do
  r=$(kubectl get model -n "$NS" "$MODEL" -o jsonpath='{.status.replicas.ready}' 2>/dev/null); r=${r:-0}
  a=$(kubectl get pods -n "$NS" -l model="$MODEL" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$r" = "0" ] && [ "$a" = "0" ] && { log "reached 0 replicas"; break; }
  sleep 5
done

log "=== done ==="
