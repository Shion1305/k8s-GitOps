#!/usr/bin/env bash
# Scale-from-zero timeline: fire one request at a model that is at 0 replicas and
# record, relative to t=0 (request sent), when each event happens:
#   - HTTP request sent / first token / response complete (client side)
#   - Pod created / scheduled / container started / Ready (k8s side)
#   - vLLM milestones from the pod log (checkpoint load, compile, warmup, serving)
#
# Run while the model is at 0 replicas. Requires kubectl + a port-forward to KubeAI.
#
# Usage:
#   kubectl -n scalable-llm port-forward svc/kubeai 8000:80 &
#   ./scalable-llm/bench/coldstart_timeline.sh
set -uo pipefail

NS=scalable-llm
MODEL=tt-llama
BASE=${BASE:-http://localhost:8000/openai/v1}
# How many consecutive zero-replica checks (1s apart) before we trust pod=0.
SETTLE=${SETTLE:-10}

echo "=== scale-from-zero timeline for $MODEL ==="

# Precondition: force a stable 0-replica state before t=0, else the measurement
# is meaningless (we'd time a warm or mid-startup pod). This needs minReplicas:0
# so the autoscaler does NOT re-create what we delete; with min:0 a deleted pod
# stays gone once active requests are zero. We actively delete any leftover /
# mid-scale-down pod and require a stable zero streak.
echo "forcing a stable 0-replica state (needs minReplicas:0)..."
min=$(kubectl get model -n "$NS" "$MODEL" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
if [ "${min:-1}" != "0" ]; then
  echo "ERROR: minReplicas is '${min:-?}', not 0 — the autoscaler would refill" >&2
  echo "       deleted pods. Merge/apply minReplicas:0 first." >&2
  exit 1
fi
streak=0
for _ in $(seq 1 300); do
  n=$(kubectl get pods -n "$NS" -l model="$MODEL" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" = "0" ]; then
    streak=$((streak + 1))
  else
    streak=0
    # delete leftover / mid-scale-down pods to drive to zero faster
    kubectl delete pod -n "$NS" -l model="$MODEL" --wait=false >/dev/null 2>&1
  fi
  [ "$streak" -ge "$SETTLE" ] && break
  sleep 1
done
if [ "$streak" -lt "$SETTLE" ]; then
  echo "ERROR: could not hold a stable 0-replica state (last count=$n)." >&2
  echo "       Something keeps sending requests (a stray client / port-forward probe)?" >&2
  exit 1
fi
echo "confirmed pod=0 (stable for ${SETTLE}s). starting timeline."

T0=$(date +%s.%N)
rel() { awk "BEGIN{printf \"%6.1f\", $(date +%s.%N) - $T0}"; }
log() { echo "[$(rel)s] $*"; }
echo "t=0 is the moment the request is sent (model confirmed at 0 replicas)."

# Background watcher: emit pod lifecycle transitions with relative timestamps.
(
  seen_created=""; seen_sched=""; seen_started=""; seen_ready=""
  while :; do
    pod=$(kubectl get pods -n $NS -l model=$MODEL -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$pod" ] && [ -z "$seen_created" ]; then seen_created=1; log "POD CREATED: $pod"; fi
    if [ -n "$pod" ]; then
      sched=$(kubectl get pod -n $NS "$pod" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].status}' 2>/dev/null)
      [ "$sched" = "True" ] && [ -z "$seen_sched" ] && { seen_sched=1; log "POD SCHEDULED"; }
      started=$(kubectl get pod -n $NS "$pod" -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)
      [ -n "$started" ] && [ -z "$seen_started" ] && { seen_started=1; log "CONTAINER STARTED"; }
      ready=$(kubectl get pod -n $NS "$pod" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
      [ "$ready" = "true" ] && [ -z "$seen_ready" ] && { seen_ready=1; log "POD READY (serving)"; break; }
    fi
    sleep 1
  done
) &
WATCH=$!

# Background log-milestone tracker: scan the pod log for key phases.
(
  declare -A hit
  while :; do
    pod=$(kubectl get pods -n $NS -l model=$MODEL -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [ -z "$pod" ] && { sleep 1; continue; }
    logs=$(kubectl logs -n $NS "$pod" 2>/dev/null | tr '\r' '\n')
    grep -q "Loading checkpoint shards: 100" <<<"$logs" && [ -z "${hit[ckpt]:-}" ] && { hit[ckpt]=1; log "  vllm: weights loaded (checkpoint shards)"; }
    grep -q "Done Compiling Model" <<<"$logs" && [ -z "${hit[compile]:-}" ] && { hit[compile]=1; log "  vllm: model compiled"; }
    grep -q "Allocating TT kv caches" <<<"$logs" && [ -z "${hit[kv]:-}" ] && { hit[kv]=1; log "  vllm: KV cache allocated"; }
    grep -q "warmup_model_prefill" <<<"$logs" && [ -z "${hit[warm]:-}" ] && { hit[warm]=1; log "  vllm: warmup started"; }
    grep -q "init engine" <<<"$logs" && [ -z "${hit[engine]:-}" ] && { hit[engine]=1; log "  vllm: engine init done"; }
    grep -q "Application startup complete" <<<"$logs" && [ -z "${hit[up]:-}" ] && { hit[up]=1; log "  vllm: Application startup complete"; break; }
    sleep 2
  done
) &
LOGW=$!

# Fire the request (streaming) and timestamp first token + completion.
log "REQUEST SENT"
python3 - "$BASE" "$MODEL" "$T0" <<'PY'
import json, sys, time, urllib.request
base, model, t0 = sys.argv[1], sys.argv[2], float(sys.argv[3])
def rel(): return time.time() - t0
body = json.dumps({"model": model, "messages": [{"role": "user", "content": "Say hello."}],
                   "max_tokens": 16, "stream": True}).encode()
req = urllib.request.Request(base.rstrip("/") + "/chat/completions", data=body,
                             headers={"Content-Type": "application/json"})
first = None
with urllib.request.urlopen(req, timeout=900) as resp:
    for raw in resp:
        line = raw.decode("utf-8", "ignore").strip()
        if not line.startswith("data:"): continue
        p = line[5:].strip()
        if p == "[DONE]": break
        try: c = json.loads(p)
        except Exception: continue
        if c.get("choices", [{}])[0].get("delta", {}).get("content"):
            if first is None:
                first = rel(); print(f"[{first:6.1f}s] FIRST TOKEN (client)")
print(f"[{rel():6.1f}s] RESPONSE COMPLETE (client)")
PY

wait $WATCH 2>/dev/null
wait $LOGW 2>/dev/null
log "=== done ==="
