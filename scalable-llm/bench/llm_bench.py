#!/usr/bin/env python3
"""Minimal dependency-free load benchmark for an OpenAI-compatible endpoint.

Measures TTFT (time to first token, via streaming), end-to-end latency, output
tokens/sec, and aggregate throughput across a sweep of concurrency levels. Uses
only the Python stdlib so it runs anywhere (no aiohttp/httpx needed).

Usage (against KubeAI via port-forward):
  kubectl -n scalable-llm port-forward svc/kubeai 8000:80 &
  python3 scalable-llm/bench/llm_bench.py \
      --base-url http://localhost:8000/openai/v1 \
      --model tt-llama \
      --concurrency 1 2 4 8 \
      --requests-per-level 16 \
      --max-tokens 128

Through LiteLLM instead (needs the master key):
  --base-url https://ai.i.shion1305.com/v1 --api-key sk-...
"""
import argparse
import json
import statistics
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

PROMPT = (
    "Explain, in a few sentences, what a Kubernetes operator is and why it is "
    "useful. Then give one concrete example."
)


def stream_one(base_url, model, api_key, max_tokens, prompt):
    """Fire one streaming chat completion. Returns (ttft, total, out_tokens) or raises."""
    body = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": 0.7,
            "stream": True,
        }
    ).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(
        base_url.rstrip("/") + "/chat/completions", data=body, headers=headers
    )
    start = time.perf_counter()
    ttft = None
    out_tokens = 0
    with urllib.request.urlopen(req, timeout=600) as resp:
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
                if ttft is None:
                    ttft = time.perf_counter() - start
                out_tokens += 1
    total = time.perf_counter() - start
    if ttft is None:
        ttft = total
    return ttft, total, out_tokens


def run_level(base_url, model, api_key, max_tokens, concurrency, n_requests):
    """Run n_requests through `concurrency` workers; return aggregate stats."""
    results = []
    errors = []
    lock = threading.Lock()

    def task(_):
        try:
            r = stream_one(base_url, model, api_key, max_tokens, PROMPT)
            with lock:
                results.append(r)
        except Exception as e:  # noqa: BLE001 - benchmark, report and continue
            with lock:
                errors.append(str(e))

    wall_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as ex:
        list(ex.map(task, range(n_requests)))
    wall = time.perf_counter() - wall_start

    if not results:
        return {"concurrency": concurrency, "ok": 0, "errors": len(errors),
                "sample_error": errors[0] if errors else ""}

    ttfts = [r[0] for r in results]
    totals = [r[1] for r in results]
    toks = [r[2] for r in results]
    total_out = sum(toks)
    # per-request decode tokens/sec (excludes ttft)
    tps = [t / max(tot - ttf, 1e-6) for (ttf, tot, t) in results if t > 0]

    def p(vals, q):
        return statistics.quantiles(vals, n=100)[q - 1] if len(vals) > 1 else vals[0]

    return {
        "concurrency": concurrency,
        "ok": len(results),
        "errors": len(errors),
        "ttft_ms_med": round(statistics.median(ttfts) * 1000, 1),
        "ttft_ms_p95": round(p(ttfts, 95) * 1000, 1),
        "latency_s_med": round(statistics.median(totals), 2),
        "latency_s_p95": round(p(totals, 95), 2),
        "decode_tps_med": round(statistics.median(tps), 1) if tps else 0,
        "agg_out_tps": round(total_out / wall, 1),
        "wall_s": round(wall, 1),
        "sample_error": errors[0] if errors else "",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True, help="OpenAI base, e.g. http://localhost:8000/openai/v1")
    ap.add_argument("--model", default="tt-llama")
    ap.add_argument("--api-key", default=None)
    ap.add_argument("--concurrency", type=int, nargs="+", default=[1, 2, 4, 8])
    ap.add_argument("--requests-per-level", type=int, default=16)
    ap.add_argument("--max-tokens", type=int, default=128)
    args = ap.parse_args()

    print(f"# endpoint={args.base_url} model={args.model} max_tokens={args.max_tokens}")
    print(f"# requests_per_level={args.requests_per_level}")
    cols = ["concurrency", "ok", "errors", "ttft_ms_med", "ttft_ms_p95",
            "latency_s_med", "latency_s_p95", "decode_tps_med", "agg_out_tps", "wall_s"]
    print("\t".join(cols))
    rows = []
    for c in args.concurrency:
        stats = run_level(args.base_url, args.model, args.api_key,
                          args.max_tokens, c, args.requests_per_level)
        rows.append(stats)
        print("\t".join(str(stats.get(k, "")) for k in cols))
        if stats.get("sample_error"):
            print(f"  # sample error @ c={c}: {stats['sample_error'][:160]}")
    # scaling summary: aggregate throughput vs concurrency
    print("\n# scaling (aggregate output tokens/sec):")
    base = next((r["agg_out_tps"] for r in rows if r["concurrency"] == args.concurrency[0] and r["ok"]), None)
    for r in rows:
        if r.get("ok"):
            factor = f"{r['agg_out_tps']/base:.2f}x" if base else "-"
            print(f"  c={r['concurrency']:>3}: {r['agg_out_tps']:>7} tok/s  ({factor} vs c={args.concurrency[0]})")


if __name__ == "__main__":
    main()
