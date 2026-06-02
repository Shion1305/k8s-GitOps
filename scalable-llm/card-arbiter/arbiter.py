#!/usr/bin/env python3
"""Card-arbiter: free a Tenstorrent card for a model that is waiting on one.

KubeAI autoscales every Model independently and has no global accelerator
arbitration (verified against KubeAI v0.23.2). With N cards and more than N
Models that can each want a card, a Model whose request arrives when all cards
are busy gets a Pod stuck Pending (Insufficient squat.io/tenstorrent) forever —
KubeAI never scales another Model down to make room.

This controller closes that gap. Each tick it asks: is some Model's Pod Pending
for a card while every card is held, and is one of the card-holding Models
idle (no in-flight requests)? If so it evicts the *idlest* holder (LRU) by
pinning its maxReplicas to 0, which makes KubeAI's own autoscaler scale it to 0
and release the card; the waiting Pod then schedules. When the pressure clears
the holder's maxReplicas is restored so it can serve again.

Idleness comes from KubeAI's own per-model in-flight count, which the autoscaler
prints every interval (KubeAI exposes no metrics endpoint):
    Calculated target replicas for model "X": ceil(0/4) = 0, current requests: sum([0]) = 0
The `sum([...])` is the live in-flight request total for that model.

Actuation is maxReplicas (not spec.replicas): KubeAI owns spec.replicas and
rewrites it every loop, but it clamps its target to maxReplicas, so 0 sticks.
ArgoCD self-heal would otherwise revert the live patch, so the scalable-llm app
lists Model spec.maxReplicas/replicas under ignoreDifferences.

Talks to the Kubernetes API directly over HTTPS with the in-cluster
ServiceAccount token — no kubectl, so the image is plain python:alpine. All
state is in-memory and re-derived each tick; a restart re-derives it.
"""

import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

NS = os.environ.get("ARBITER_NAMESPACE", "scalable-llm")
# The extended resource one card is advertised as (device-plugin.yaml).
CARD_RESOURCE = os.environ.get("ARBITER_CARD_RESOURCE", "squat.io/tenstorrent")
# The node that carries the cards; total capacity is read from its allocatable.
CARD_NODE = os.environ.get("ARBITER_CARD_NODE", "shion-ubuntu-2605")
# KubeAI controller pods carry the per-model in-flight counts in their log.
KUBEAI_SELECTOR = os.environ.get(
    "ARBITER_KUBEAI_SELECTOR", "app.kubernetes.io/name=kubeai"
)
# Poll period. The reaction floor is one tick; cold start is ~140s, so a few
# seconds of arbiter latency is noise against that.
INTERVAL = float(os.environ.get("ARBITER_INTERVAL_SECONDS", "5"))
# A holder must have read sum==0 for this long before it is evictable. Guards
# against evicting a model between two requests of a bursty-but-active client.
# Keep this BELOW KubeAI's own idle scale-down (timeWindow + scaleDownDelay,
# ~60-70s): an idle minReplicas:0 holder self-scales to 0 on that schedule, so a
# longer grace means KubeAI frees the card before the arbiter ever acts. A
# shorter grace lets the arbiter win the race when the card is genuinely needed.
IDLE_GRACE = float(os.environ.get("ARBITER_IDLE_GRACE_SECONDS", "20"))
# After eviction, keep the holder pinned at 0 at least this long so the freed
# card is actually consumed by the waiter before the victim can reclaim it.
EVICT_HOLD = float(os.environ.get("ARBITER_EVICT_HOLD_SECONDS", "120"))
# How many log lines to scan for the latest per-model in-flight counts.
LOG_TAIL_LINES = os.environ.get("ARBITER_LOG_TAIL_LINES", "40")

API = "https://kubernetes.default.svc"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"

# `sum([12, 0, 3]) = 15` from the autoscaler line — capture the model name and
# the bracketed list; we sum it ourselves rather than trust the printed total.
_SUM_RE = re.compile(
    r'Calculated target replicas for model "([^"]+)".*current requests: sum\(\[([^\]]*)\]\)'
)


def log(msg):
    print(f"[arbiter] {msg}", flush=True)


def _token():
    with open(f"{SA}/token") as f:
        return f.read().strip()


_ssl_ctx = None


def _ssl_context():
    # Built lazily, not at import, so the module imports off-cluster (where the
    # SA cert is absent) — keeps the logic unit-testable and avoids a crash if
    # the cert is briefly unreadable at startup.
    global _ssl_ctx
    if _ssl_ctx is None:
        _ssl_ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    return _ssl_ctx


def api(path, method="GET", body=None, content_type="application/json", raw=False):
    """Call the in-cluster Kubernetes API. Returns parsed JSON, or text if raw."""
    url = API + path
    data = None
    headers = {"Authorization": f"Bearer {_token()}", "Accept": "application/json"}
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        headers["Content-Type"] = content_type
    if raw:
        headers["Accept"] = "*/*"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15, context=_ssl_context()) as resp:
        text = resp.read().decode("utf-8", "replace")
    return text if raw else json.loads(text)


def card_capacity():
    """Total cards advertised by the node (allocatable). 0 if unreadable."""
    try:
        node = api(f"/api/v1/nodes/{CARD_NODE}")
        return int(node.get("status", {}).get("allocatable", {}).get(CARD_RESOURCE, 0))
    except Exception as e:
        log(f"card_capacity error: {e!r}")
        return 0


def model_pods():
    """KubeAI model Pods in the namespace: list of (model, phase, reason)."""
    sel = urllib.parse.quote("app.kubernetes.io/managed-by=kubeai")
    try:
        data = api(f"/api/v1/namespaces/{NS}/pods?labelSelector={sel}")
    except Exception as e:
        log(f"model_pods error: {e!r}")
        return []
    pods = []
    for p in data.get("items", []):
        model = p["metadata"].get("labels", {}).get("model")
        if not model:
            continue
        phase = p.get("status", {}).get("phase", "")
        reason = ""
        for c in p.get("status", {}).get("conditions", []):
            if c.get("type") == "PodScheduled" and c.get("status") == "False":
                reason = (c.get("reason", "") or "") + ":" + (c.get("message", "") or "")
        pods.append((model, phase, reason))
    return pods


def in_flight_by_model():
    """Per-model live in-flight request count, parsed from the KubeAI log tail."""
    sel = urllib.parse.quote(KUBEAI_SELECTOR)
    try:
        data = api(f"/api/v1/namespaces/{NS}/pods?labelSelector={sel}")
        names = [p["metadata"]["name"] for p in data.get("items", [])]
    except Exception as e:
        log(f"kubeai pod lookup error: {e!r}")
        return {}
    counts = {}
    for name in names:
        try:
            logs = api(
                f"/api/v1/namespaces/{NS}/pods/{name}/log?tailLines={LOG_TAIL_LINES}",
                raw=True,
            )
        except Exception as e:
            log(f"log read error for {name}: {e!r}")
            continue
        for m in _SUM_RE.finditer(logs):
            model, body = m.group(1), m.group(2).strip()
            nums = [int(x) for x in re.findall(r"-?\d+", body)]
            counts[model] = sum(nums)  # last (most recent) line for a model wins
    return counts


def model_bounds(model):
    """Return (minReplicas, maxReplicas) from the Model spec; None on error."""
    try:
        spec = api(f"/apis/kubeai.org/v1/namespaces/{NS}/models/{model}").get("spec", {})
        mn = spec.get("minReplicas")
        mx = spec.get("maxReplicas")
        return (0 if mn is None else int(mn), None if mx is None else int(mx))
    except Exception as e:
        log(f"read bounds error for {model}: {e!r}")
        return None


def set_bounds(model, minr, maxr):
    # Pin BOTH bounds. maxReplicas alone is not enough: KubeAI's
    # enforceReplicaBounds applies max first then min, so min wins — a warm
    # holder (minReplicas>=1) re-clamps back up and never releases its card
    # unless minReplicas is lowered too. Restoring puts both back.
    api(
        f"/apis/kubeai.org/v1/namespaces/{NS}/models/{model}",
        method="PATCH",
        body={"spec": {"minReplicas": minr, "maxReplicas": maxr}},
        content_type="application/merge-patch+json",
    )


def main():
    log(
        f"start ns={NS} resource={CARD_RESOURCE} node={CARD_NODE} "
        f"interval={INTERVAL}s idle_grace={IDLE_GRACE}s evict_hold={EVICT_HOLD}s"
    )
    log(f"card capacity = {card_capacity()}")

    # model -> monotonic time it was first observed idle (reset whenever busy).
    idle_since = {}
    # model -> (orig_min, orig_max, monotonic time pinned) for evicted holders.
    evicted = {}

    while True:
        try:
            tick(idle_since, evicted)
        except Exception as e:  # never let one bad tick kill the loop
            log(f"tick error: {e!r}")
        time.sleep(INTERVAL)


def tick(idle_since, evicted):
    now = time.monotonic()
    capacity = card_capacity()
    pods = model_pods()
    inflight = in_flight_by_model()

    running = [m for (m, phase, _) in pods if phase == "Running"]
    pending_for_card = [
        m for (m, phase, reason) in pods
        if phase == "Pending" and (
            "Insufficient" in reason or CARD_RESOURCE in reason
        )
    ]
    # Cards in use = running model pods (one card each). Pending pods hold none.
    free_cards = capacity - len(running)

    # Track idleness for every running holder.
    for m in running:
        if inflight.get(m, 0) > 0:
            idle_since.pop(m, None)
        else:
            idle_since.setdefault(m, now)
    # Drop idleness state for models no longer running.
    for m in list(idle_since):
        if m not in running:
            idle_since.pop(m, None)

    # Restore any evicted holder once pressure is gone and the hold has elapsed.
    for m in list(evicted):
        orig_min, orig_max, pinned_at = evicted[m]
        if not pending_for_card and (now - pinned_at) >= EVICT_HOLD:
            log(f"restore: model={m} bounds ->(min={orig_min},max={orig_max}) (pressure cleared)")
            try:
                set_bounds(m, orig_min, orig_max)
                evicted.pop(m, None)
            except Exception as e:
                log(f"restore failed for {m}: {e!r}")

    if not pending_for_card:
        return
    if free_cards > 0:
        # A card is free; the scheduler will place the waiter on its own.
        log(f"waiters={pending_for_card} free_cards={free_cards}; scheduler will place")
        return

    # Pressure: a model needs a card and none is free. Evictable holders are
    # running, not already evicted, and idle for >= IDLE_GRACE.
    candidates = []
    for m in running:
        if m in evicted:
            continue
        since = idle_since.get(m)
        if since is None:
            continue  # currently serving
        idle_for = now - since
        if idle_for >= IDLE_GRACE:
            candidates.append((idle_for, m))

    if not candidates:
        ages = {k: round(now - v) for k, v in idle_since.items()}
        log(
            f"PRESSURE waiters={pending_for_card} free=0 holders={running} "
            f"— no idle-enough victim (idle_for={ages}); waiting"
        )
        return

    # LRU: evict the holder idle the longest.
    candidates.sort(reverse=True)
    idle_for, victim = candidates[0]
    bounds = model_bounds(victim)
    if bounds is None:
        log(f"victim={victim}: could not read bounds; skip")
        return
    orig_min, orig_max = bounds
    if orig_max == 0:
        log(f"victim={victim} already has maxReplicas=0; skip")
        return
    log(
        f"EVICT victim={victim} (idle {round(idle_for)}s) "
        f"bounds (min={orig_min},max={orig_max})->(0,0) to free a card for {pending_for_card}"
    )
    try:
        set_bounds(victim, 0, 0)
        evicted[victim] = (orig_min, orig_max, now)
    except Exception as e:
        log(f"evict failed for {victim}: {e!r}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
