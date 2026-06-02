#!/usr/bin/env bash
# Preemption demo, warm-primary variant. Assumes PRIMARY is already a warm
# holder of cards (e.g. minReplicas pinned so KubeAI won't self-release), and
# currently idle. Fires one WAITER request and records the arbiter freeing a
# card: WAITER goes Pending, the arbiter evicts an idle PRIMARY replica
# (maxReplicas->0), the card frees, WAITER becomes Ready.
#
# This is the scenario the arbiter exists for: a Running-but-idle holder that
# KubeAI will NOT scale down on its own. (With every model at minReplicas:0 an
# idle holder self-scales to 0 in ~60s, before the arbiter's idle grace, so the
# arbiter rarely needs to act — it matters for warm/pinned or trickle-loaded
# holders.)
#
# Usage (after pinning PRIMARY warm and letting it reach its replica count):
#   kubectl -n scalable-llm port-forward svc/kubeai 8000:80 &
#   ./scalable-llm/bench/preempt_warm.sh
set -uo pipefail

NS=scalable-llm
PRIMARY=${PRIMARY:-tt-llama}
WAITER=${WAITER:-tt-llama-b}
BASE=${BASE:-http://localhost:8000/openai/v1}
# How long to wait for the idle grace + eviction + waiter cold start.
PREEMPT_SECS=${PREEMPT_SECS:-360}

T0=$(date +%s.%N)
rel() { awk "BEGIN{printf \"%6.1f\", $(date +%s.%N) - $T0}"; }
log() { echo "[$(rel)s] $*"; }
ready() { kubectl get model -n "$NS" "$1" -o jsonpath='{.status.replicas.ready}' 2>/dev/null; }
allrep() { kubectl get model -n "$NS" "$1" -o jsonpath='{.status.replicas.all}' 2>/dev/null; }
maxrep() { kubectl get model -n "$NS" "$1" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null; }
pending_for_card() {
  kubectl get pods -n "$NS" -l "model=$1" -o json 2>/dev/null | python3 -c '
import json,sys
n=0
for p in json.load(sys.stdin).get("items",[]):
    if p.get("status",{}).get("phase")=="Pending":
        for c in p.get("status",{}).get("conditions",[]):
            if c.get("type")=="PodScheduled" and c.get("status")=="False" and "Insufficient" in (c.get("message","") or ""):
                n+=1
print(n)'
}

echo "=== preemption (warm primary) ==="
log "start: $PRIMARY ready=$(ready $PRIMARY) max=$(maxrep $PRIMARY) | $WAITER ready=$(ready $WAITER)"

# Background pollers (state + arbiter decisions) on one clock.
(
  prev=""
  while :; do
    cur="$PRIMARY ready=$(ready $PRIMARY) all=$(allrep $PRIMARY) max=$(maxrep $PRIMARY) | $WAITER ready=$(ready $WAITER) all=$(allrep $WAITER) pending=$(pending_for_card $WAITER)"
    [ "$cur" != "$prev" ] && { log "STATE  $cur"; prev="$cur"; }
    sleep 2
  done
) & POLL=$!
(
  kubectl logs -n "$NS" -l app=card-arbiter -f --tail=0 2>/dev/null | while IFS= read -r line; do
    case "$line" in *EVICT*|*restore*|*PRESSURE*) log "ARBITER $line";; esac
  done
) & ALOG=$!
trap 'kill $POLL $ALOG 2>/dev/null' EXIT

log "firing one $WAITER request (it has no free card -> must preempt)"
curl -s -m 300 "$BASE/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"'"$WAITER"'","messages":[{"role":"user","content":"Say hello in one sentence."}],"max_tokens":32,"stream":false}' \
  >/tmp/waiter_resp.json 2>&1 &
REQ=$!

end=$(( $(date +%s) + PREEMPT_SECS ))
saw_pending=0
while [ "$(date +%s)" -lt "$end" ]; do
  [ "$(pending_for_card $WAITER)" -ge 1 ] && [ "$saw_pending" = 0 ] && { saw_pending=1; log ">> $WAITER PENDING for a card (contention) — arbiter should now act"; }
  if [ "$(ready $WAITER)" = "1" ]; then
    log ">> $WAITER READY — preemption succeeded, card was freed by the arbiter"
    break
  fi
  sleep 3
done

wait "$REQ" 2>/dev/null
log "waiter response: $(head -c 200 /tmp/waiter_resp.json 2>/dev/null)"
log "final: $PRIMARY ready=$(ready $PRIMARY) max=$(maxrep $PRIMARY) | $WAITER ready=$(ready $WAITER)"
log "=== done ==="
