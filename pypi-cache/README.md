# pypi-cache — in-cluster PyPI pull-through cache (proxpi)

A lightweight [proxpi](https://github.com/EpicWink/proxpi) deployment that caches
PyPI wheels in-cluster so CI (and any in-cluster `pip`/`uv`) fetches each wheel
from the WAN **once**, then serves every subsequent pull from the home LAN.

## Why this exists

The ATC CI jobs spend ~150s/job in `uv sync` downloading ~200 MB of wheels
(pyarrow, scipy, polars, numpy, marimo, …) from PyPI over the WAN. The wheel
*content* is identical every run, but nothing in-cluster caches it. This is the
"move the artifact source in-cluster" half of the CI-cache work (the other half —
a warm CPython hostedtoolcache + aqua/uv baked into the runner image — lives in
the `crypto-auto-trading` repo).

## Why proxpi and not a plain reverse-proxy

PyPI's simple API returns **absolute** wheel URLs on `files.pythonhosted.org`, so
a naive nginx proxy of the index host serves the index but lets the client fetch
wheels straight from PyPI — uncached. proxpi rewrites those file URLs to route
through itself (`/index/<pkg>/<file>`) and caches the bytes; that rewrite is the
whole point. devpi does the same but has no official image and needs index/user
init — proxpi is a single gunicorn process purpose-built for exactly this.

## Consumer contract (do not break without updating consumers)

- **Service:** `proxpi.pypi-cache.svc.cluster.local:5000`
- **Index endpoint:** `/index/` (PEP 503 simple API)

The `crypto-auto-trading` CI runner image (`Dockerfile.ci-runner`) bakes these
env vars so `uv sync` uses the cache transparently — **zero per-repo workflow
edits**:

```dockerfile
ENV UV_DEFAULT_INDEX=http://proxpi.pypi-cache.svc.cluster.local:5000/index/ \
    UV_INSECURE_HOST=proxpi.pypi-cache.svc.cluster.local:5000
```

`UV_INSECURE_HOST` is required because proxpi speaks plain HTTP in-cluster; uv
refuses an `http://` index otherwise. This is an in-cluster-only plaintext hop
within one trust domain (Cilium-policed pod network), not internet-facing, so TLS
is not warranted here.

**Lockfile integrity is preserved:** proxpi returns byte-identical upstream
wheels, so the hashes pinned in `uv.lock` still verify. The cache changes *where*
a wheel comes from, never *what* it is.

## Operational notes

- **Single replica + node-local `emptyDir` cache** (`sizeLimit: 20Gi`). The
  cache is a disposable warm-up optimisation, so it does **not** use longhorn:
  replicated HDD storage put the only replica on a different node than proxpi,
  forcing every "cached" wheel read across the ~0.6 MB/s home WireGuard link (the
  cause of the old bimodal 30s-vs-4min `uv` latency). An `emptyDir` keeps all
  cache I/O on proxpi's own node. Trade-off: the cache is lost on pod
  restart/reschedule and re-warms from PyPI on the next pulls — acceptable for a
  warm-up cache. Never scale to >1 replica; `strategy: Recreate` keeps one
  writer.
- **Placement:** `nodeSelector: kubernetes.io/arch: amd64` co-locates proxpi with
  the `shion1305-amd` GARM runners — the only amd64 nodes are the home nodes, so
  proxpi stays on the home LAN and off the cross-site OCI nodes.
- **Eviction:** `PROXPI_CACHE_SIZE=16Gi` (LRU) sits below the 20Gi `emptyDir`
  `sizeLimit` so proxpi evicts before the kubelet does.
- **Index freshness:** `PROXPI_INDEX_TTL=1800s` — new releases appear within 30
  min; the wheel *files* are immutable and cached indefinitely (until LRU-evicted).
- **Image:** `epicwink/proxpi` pinned by digest (Docker Hub is its only channel).
  A Harbor `docker.io` proxy-cache project could front it later; the digest pin
  already makes the pull reproducible.

## Validation

Verified end-to-end locally (proxpi + a real `pip`/`uv` install): the index and
every wheel are served through proxpi (`GET /index/<pkg>/<file>` 200), and wheels
persist to the cache dir (`files-pythonhosted-org/packages/.../<pkg>.whl`). A
second install of the same package is served entirely from the cache.

## Benchmark

`bench/run.sh` measures cache-hit `uv` install latency and N-way concurrency
against the live in-cluster proxpi, and prints a summary table. CI runs it via
[`.github/workflows/pypi-cache-benchmark.yaml`](../.github/workflows/pypi-cache-benchmark.yaml)
on the `shion1305-amd` runner (in-cluster, so it can reach the Service) whenever
`pypi-cache/**` changes — run it before/after infra changes to quantify the
effect. See `bench/run.sh` for the tunable knobs (`CONCURRENCY`, threshold
gates).
