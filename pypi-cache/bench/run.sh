#!/usr/bin/env bash
# Benchmark the in-cluster proxpi PyPI cache: cache-hit `uv` install latency and
# N-way concurrency (the CI thundering-herd). Meant to run on a shion1305-amd
# GARM runner, which is in-cluster and can reach the proxpi Service.
#
# Method: each measured install uses a FRESH UV_CACHE_DIR so uv's own cache never
# masks proxpi -- every wheel is re-fetched from proxpi. A warm-up pass first
# populates proxpi, so the reported "warm" number is steady-state LAN serving
# (the metric that dropped from minutes to seconds when the cache went
# node-local). Absolute numbers depend on cache warmth; keep the pinned
# requirements.txt fixed for run-to-run comparability. This loads the shared
# production proxpi, so CI gates it to pypi-cache/** changes only.
#
# Knobs (env): CONCURRENCY (default 8), REPEATS (default 3), THRESHOLD_WARM_S /
# THRESHOLD_CONC_S (seconds; >0 fails the run if exceeded, else informational).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ="$HERE/requirements.txt"

export UV_DEFAULT_INDEX="${UV_DEFAULT_INDEX:-http://proxpi.pypi-cache.svc.cluster.local:5000/index/}"
export UV_INSECURE_HOST="${UV_INSECURE_HOST:-proxpi.pypi-cache.svc.cluster.local:5000}"
# Only ever resolve through proxpi (never fall back to pypi.org) so we measure
# the cache, not the WAN.
export UV_INDEX_STRATEGY="${UV_INDEX_STRATEGY:-first-index}"

CONCURRENCY="${CONCURRENCY:-8}"
REPEATS="${REPEATS:-3}"
THRESHOLD_WARM_S="${THRESHOLD_WARM_S:-0}"
THRESHOLD_CONC_S="${THRESHOLD_CONC_S:-0}"
# Pin the interpreter so the resolved wheel set (and thus byte volume) is fixed
# regardless of the runner's default Python; all pinned wheels have cp312 builds.
PYVER="${PYVER:-3.12}"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found; installing..." >&2
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
fi
echo "uv: $(uv --version)  index: $UV_DEFAULT_INDEX"
# Pre-fetch the managed interpreter (from python-build-standalone, not proxpi) so
# it is not counted in any measured install.
uv python install "$PYVER" >/dev/null 2>&1 || true

# One isolated install with a fresh uv cache into a throwaway target. Prints the
# elapsed seconds to stdout; all uv noise goes to stderr. Returns non-zero (and
# prints the tail of uv's output) on failure.
install_once() {
  local cache target start end rc=0
  cache="$(mktemp -d)"; target="$(mktemp -d)"
  start="$(date +%s.%N)"
  if ! UV_CACHE_DIR="$cache" uv pip install \
        --python "$PYVER" \
        --target "$target" --no-progress -r "$REQ" >/dev/null 2>"$cache/err"; then
    rc=1; echo "install failed:" >&2; tail -n 20 "$cache/err" >&2
  fi
  end="$(date +%s.%N)"
  # Record installed (unpacked) size once, for a rough throughput figure.
  [ -f /tmp/bench_payload_kb ] || du -sk "$target" 2>/dev/null | cut -f1 >/tmp/bench_payload_kb
  rm -rf "$cache" "$target"
  awk -v a="$start" -v b="$end" 'BEGIN{printf "%.1f", b-a}'
  return "$rc"
}

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }

echo "== warm-up (populate proxpi) =="
install_once >/dev/null || { echo "warm-up failed -- proxpi unreachable?" >&2; exit 1; }

echo "== sequential warm x${REPEATS} =="
warm_samples=()
for _ in $(seq 1 "$REPEATS"); do
  t="$(install_once)"; echo "  ${t}s"; warm_samples+=("$t")
done
WARM="$(median "${warm_samples[@]}")"

echo "== concurrency x${CONCURRENCY} =="
cdir="$(mktemp -d)"; wstart="$(date +%s.%N)"; pids=()
for i in $(seq 1 "$CONCURRENCY"); do ( install_once >"$cdir/t$i" ) & pids+=("$!"); done
CONC_FAIL=0
for p in "${pids[@]}"; do wait "$p" || CONC_FAIL=1; done
wend="$(date +%s.%N)"
CONC_WALL="$(awk -v a="$wstart" -v b="$wend" 'BEGIN{printf "%.1f", b-a}')"
CONC_SLOWEST="$(sort -n "$cdir"/t* | tail -n1)"
rm -rf "$cdir"

PAYLOAD_MB="$(awk '{printf "%.0f", $1/1024}' /tmp/bench_payload_kb 2>/dev/null || echo 0)"
WARM_MBPS="$(awk -v mb="$PAYLOAD_MB" -v s="$WARM" 'BEGIN{if(s>0)printf "%.1f", mb/s; else print "n/a"}')"
CONC_MBPS="$(awk -v mb="$PAYLOAD_MB" -v n="$CONCURRENCY" -v s="$CONC_WALL" 'BEGIN{if(s>0)printf "%.1f", (mb*n)/s; else print "n/a"}')"
rm -f /tmp/bench_payload_kb

# --- report ---
{
  echo "## proxpi cache benchmark"
  echo
  echo "Requirements: \`pypi-cache/bench/requirements.txt\` (~${PAYLOAD_MB} MB unpacked/install)"
  echo
  echo "| Metric | Value |"
  echo "| --- | --- |"
  echo "| Warm install (median of ${REPEATS}) | ${WARM}s (~${WARM_MBPS} MB/s) |"
  echo "| Concurrency ${CONCURRENCY}: wall clock | ${CONC_WALL}s (agg ~${CONC_MBPS} MB/s) |"
  echo "| Concurrency ${CONCURRENCY}: slowest job | ${CONC_SLOWEST}s |"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

rc=0
[ "$CONC_FAIL" -eq 0 ] || { echo "::error::one or more concurrent installs failed"; rc=1; }
if awk -v v="$WARM" -v t="$THRESHOLD_WARM_S" 'BEGIN{exit !(t>0 && v>t)}'; then
  echo "::error::warm ${WARM}s > ${THRESHOLD_WARM_S}s"; rc=1
fi
if awk -v v="$CONC_SLOWEST" -v t="$THRESHOLD_CONC_S" 'BEGIN{exit !(t>0 && v>t)}'; then
  echo "::error::slowest concurrent ${CONC_SLOWEST}s > ${THRESHOLD_CONC_S}s"; rc=1
fi
exit "$rc"
