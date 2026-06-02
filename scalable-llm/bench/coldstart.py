#!/usr/bin/env python3
"""Measure scale-from-zero cold start for a KubeAI model.

Sends one chat request to a model that may be scaled to zero and reports the
wall time until the first token arrives. KubeAI holds (does not drop) the request
while it spins up a replica, so this captures: pod schedule + weight load (from
the persistent cache) + TT-Metal compile (from cache) + warmup + first decode.

Run it when the model is at zero replicas to get the true cold start; run it
again immediately after (warm) to get the baseline to subtract.

Usage:
  kubectl -n scalable-llm port-forward svc/kubeai 8000:80 &
  python3 scalable-llm/bench/coldstart.py \
      --base-url http://localhost:8000/openai/v1 --model tt-llama
"""
import argparse
import json
import time
import urllib.request


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--model", default="tt-llama")
    ap.add_argument("--api-key", default=None)
    ap.add_argument("--max-tokens", type=int, default=16)
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()

    body = json.dumps({
        "model": args.model,
        "messages": [{"role": "user", "content": "Say hi."}],
        "max_tokens": args.max_tokens,
        "stream": True,
    }).encode()
    headers = {"Content-Type": "application/json"}
    if args.api_key:
        headers["Authorization"] = f"Bearer {args.api_key}"
    req = urllib.request.Request(
        args.base_url.rstrip("/") + "/chat/completions", data=body, headers=headers
    )

    print(f"# sending one request to {args.model} (cold start if at 0 replicas)...")
    start = time.perf_counter()
    first = None
    out = 0
    with urllib.request.urlopen(req, timeout=args.timeout) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"):
                continue
            payload = line[len("data:"):].strip()
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError:
                continue
            delta = chunk.get("choices", [{}])[0].get("delta", {})
            if delta.get("content"):
                if first is None:
                    first = time.perf_counter() - start
                out += 1
    total = time.perf_counter() - start
    print(f"time_to_first_token_s : {first:.1f}" if first else "no tokens")
    print(f"total_s               : {total:.1f}")
    print(f"output_tokens         : {out}")


if __name__ == "__main__":
    main()
