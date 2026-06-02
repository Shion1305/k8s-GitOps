# scalable-llm — KubeAI on Tenstorrent Blackhole (PoC)

OpenAI-compatible inference on **Tenstorrent Blackhole** via the official
**tt-inference-server vLLM** image, orchestrated by **KubeAI**, fronted by
**LiteLLM**.

**Hardware (verified):** `shion-ubuntu-2605` has **2× Blackhole p150a** (32GB
each), tt-kmd 2.8.0, FW 19.6.0.0. tt-inference-server has no 2-card (p150x2)
mesh, and **Llama-3.1-8B** (the only LLM it supports on p150) fits one card — so
the design is **one card per replica**: the device-plugin advertises
`squat.io/tenstorrent: 2` and each model replica takes one card. The second card
backs a second replica (`maxReplicas: 2`) later.

All TT workloads are pinned to **`shion-ubuntu-2605`** (`ssh s2605`) — the only
node with cards. Everything in this namespace is GitOps-managed; do not
`kubectl apply` / `helm install` by hand (kubectl is for inspection only).

## ArgoCD apps

| App | Path | Role |
|-----|------|------|
| `kube-ai-crd` | `apps/kube-ai-crd/` | `models.kubeai.org` CRD only, sync-wave `-1` (before everything else) |
| `scalable-llm` | `apps/scalable-llm-app.yaml` | KubeAI controller (Helm, `skipCrds`) + this dir's manifests |

KubeAI chart is pinned to **0.23.2**. When bumping it, re-vendor the CRD and keep
the two in lockstep:

```bash
helm repo add kubeai https://www.kubeai.org && helm repo update
helm template kubeai kubeai/kubeai --version <new> --include-crds \
  | yq 'select(.kind=="CustomResourceDefinition")' > apps/kube-ai-crd/crds.yaml
```

## What lives here

```
scalable-llm/
├── namespace.yaml          # ns: scalable-llm
├── device-plugin.yaml      # generic-device-plugin: 1 card = 1 unit -> squat.io/tenstorrent:2
├── kubeai-values.yaml      # KubeAI Helm values: resourceProfile + tt image + cache/HF/hugepages patches
├── llama-hf-token.yaml     # ESO: Vault scalable-llm/llama → HF_TOKEN Secret (gated Llama-3.1-8B)
├── models/tt-llama.yaml    # KubeAI Model: Llama-3.1-8B on one p150 card (warm primary, max 2)
├── models/tt-llama-b.yaml  # KubeAI Model: same Llama-3.1-8B, second name (sleep-mode, max 1)
├── card-arbiter/           # frees an idle model's card for a model waiting on one
└── litellm/                # LiteLLM front + DB (shared Postgres) + Vault key + HTTPRoute
```

Endpoint (internal Gateway, WireGuard-only): **`https://ai.i.shion1305.com`**
→ LiteLLM → KubeAI (`kubeai.scalable-llm.svc`) → TT vLLM Pod.

---

## Host-side prerequisites (NOT GitOps — run on `s2605`)

These are the hardware steps the cluster cannot do for you. Do them before the
apps can become healthy. The plan's Phases 0–2 in full; summarized here.

### Phase 1-1/1-2 — on `ssh s2605`

```bash
# tt-kmd + firmware + HugePages + tt-smi via the official installer.
# containerd is the runtime here, so do NOT install Podman/Docker.
curl -fsSL https://github.com/tenstorrent/tt-installer/releases/latest/download/install.sh -O
chmod +x install.sh && ./install.sh --help        # confirm flags for your version
./install.sh \
  --mode-non-interactive \
  --install-container-runtime=no \
  --no-install-metalium-container \
  --no-install-inference-server \
  --no-install-studio
sudo reboot                                        # KMD load / HugePages

# After reboot: both cards visible, mesh healthy
source ~/.tenstorrent-venv/bin/activate            # if tt-smi not on PATH
tt-smi                                              # expect 2x Blackhole
tt-topology                                         # configure + verify the 2-card mesh
ls -l /dev/tenstorrent/ /dev/tenstorrent/by-id/     # devices 0 and 1

# Pre-create the node-local TT compile/weights cache (mounted by every model Pod).
# Owned by uid 1000 because the model Pod runs as the TT image's container_app_user
# (uid 1000) with ALL caps dropped — it must be able to write here. Use chown -R
# so any root-owned leftovers from a docker smoke test don't block writes.
sudo mkdir -p /var/local-storage/tt-cache && sudo chown -R 1000:1000 /var/local-storage/tt-cache
```

### Phase 1-3 — cluster side (from your kubectl host)

```bash
kubectl label node shion-ubuntu-2605 tenstorrent.com/blackhole=true
kubectl describe node shion-ubuntu-2605 | grep -i taint   # mirror any taint into kubeai-values
```

### Phase 2 — official image, no custom build

We use Tenstorrent's published image directly (no Dockerfile to build):
`ghcr.io/tenstorrent/tt-inference-server/vllm-tt-metal-src-release-ubuntu-22.04-amd64:0.10.0-555f240-22be241`
(public on ghcr; pinned in `kubeai-values.yaml` and `models/tt-llama.yaml`).

Optional host smoke test (outside Kubernetes) once the HF token is in your
shell — proves the card + weights + server before relying on KubeAI:

```bash
# on s2605; docker is installed there. Needs HF_TOKEN (gated Llama-3.1-8B).
docker run --rm \
  --env HF_TOKEN=$HF_TOKEN \
  --env CACHE_ROOT=/home/container_app_user/cache_root \
  --ipc host \
  --device /dev/tenstorrent \
  --mount type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G \
  -v tt_llama_cache:/home/container_app_user/cache_root \
  -p 8000:8000 \
  ghcr.io/tenstorrent/tt-inference-server/vllm-tt-metal-src-release-ubuntu-22.04-amd64:0.10.0-555f240-22be241 \
  --model Llama-3.1-8B --tt-device p150
curl localhost:8000/v1/models
```

The image entrypoint downloads the weights (first run, slow), compiles TT-Metal
kernels (cached under `CACHE_ROOT`), and serves the OpenAI API on :8000.

---

## The one remaining out-of-band step: the HF token

Everything else is wired in git. Llama-3.1-8B is **gated** on Hugging Face, so the
weight download needs your HF token (accept the model's license on huggingface.co
first, then create a read token). Write it to Vault; ESO syncs it and the model
Pod picks it up:

```bash
vault kv put scalable-llm/llama hf_token=hf_xxx
# force-sync (else waits up to 5m):
kubectl annotate externalsecret -n scalable-llm llama-hf-token force-sync="$(date +%s)" --overwrite
```

## Secrets (out-of-band, public repo — never commit values)

```bash
# Vault KV v2 mount + LiteLLM master key + HF token
vault secrets enable -path=scalable-llm kv-v2
vault kv put scalable-llm/litellm master_key=sk-<random>
vault kv put scalable-llm/llama   hf_token=hf_<your-token>
# Vault policy + k8s auth role: run vault/scripts/setup-eso-policies.sh (eso-scalable-llm added)
```

The `litellm` DB user/database are declared in `postgres-shared/postgres-cluster.yaml`;
the operator generates the credential Secret, ESO copies it in
(`litellm-db-credentials`). RBAC: `external-secrets/rbac-db-reader.yaml`
(`eso-db-scalable-llm`). Postgres-side ingress allow:
`postgres-shared/networkpolicy.yaml` (added `scalable-llm`).

## Verify (Phase 7)

```bash
kubectl -n argocd get applications kube-ai-crd scalable-llm
kubectl get crd | grep kubeai.org
kubectl -n scalable-llm get pods
kubectl get node shion-ubuntu-2605 -o json | jq '.status.capacity' | grep tenstorrent
kubectl -n scalable-llm get model tt-llama -o yaml

# through KubeAI directly
kubectl -n scalable-llm port-forward svc/kubeai 8000:80
curl http://localhost:8000/openai/v1/models

# through LiteLLM (the published front)
curl https://ai.i.shion1305.com/v1/chat/completions \
  -H "Authorization: Bearer sk-<your-litellm-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"tt-llama","messages":[{"role":"user","content":"hello"}]}'
```

## Benchmarking & scale (Phase 7)

Two dependency-free load tools live in `bench/`:

```bash
kubectl -n scalable-llm port-forward svc/kubeai 8000:80 &
# throughput / latency sweep across concurrency levels
python3 scalable-llm/bench/llm_bench.py --base-url http://localhost:8000/openai/v1 \
    --model tt-llama --concurrency 1 8 16 32 --requests-per-level 16 --max-tokens 128
# scale-from-zero cold start (run when at 0 replicas)
python3 scalable-llm/bench/coldstart.py --base-url http://localhost:8000/openai/v1 --model tt-llama
```

Measured on one **p150a** card (Llama-3.1-8B-Instruct, BF16):

| concurrency | TTFT med | agg tok/s | note |
|-------------|----------|-----------|------|
| 1  | 170 ms | 28  | single-stream |
| 16 | 930 ms | ~212 | **saturation** (continuous batching full) |
| 32 | 980 ms | ~212 | flat — batch is full |
| 128 | 14 s | ~250 | TTFT explodes; 0 errors (requests queue, don't drop) |

So one card saturates around **concurrency 16 / ~212 tok/s**; beyond that TTFT grows
while throughput is flat — the signal to scale out to the second card.

**Cold start:** first ever start ~10 min (16 GB weight download + TT-Metal compile).
Subsequent starts reuse the hostPath cache — checkpoint load <1 s, full warmup
~2–2.5 min. This is what makes warm (`minReplicas: 1`) cheap to keep and
scale-from-zero viable.

**Horizontal scale:** the node has two cards, so `maxReplicas: 2` lets KubeAI run
a replica per card under load. The memory request is **8Gi** (a replica uses only
~3.3Gi of host RAM — weights live in card VRAM); the old 32Gi request was ~10×
reality and blocked the second replica from scheduling (2×32Gi > the node's ~52Gi).

## Multi-model card sharing (card-arbiter)

The goal is to host several models that mostly sleep (`minReplicas: 0`) and run
1–2 at a time on the 2 cards, scaling by load. The hard part: **KubeAI has no
global accelerator arbitration** (verified against v0.23.2). It autoscales every
Model independently — desired replicas = `ceil(avgActiveRequests / targetRequests)`
clamped to that model's min/max, with no awareness of free cards or other models.
So when both cards are busy and a third model gets a request, its Pod sits
`Pending` (Insufficient `squat.io/tenstorrent`) forever; KubeAI never scales
another model down to make room. Its only priority lever, `priorityClassName`,
delegates to the Kubernetes scheduler, which preempts by *priority* and is blind
to *idleness* — it would evict a low-priority pod that is actively serving and
never evict an equal-priority idle one. That does not match the requirement.

`card-arbiter/` is a small single-replica controller that closes the gap. Each
tick (~5s) it reads:

- **Pending-for-card model Pods** (the waiters), from the pod list.
- **Card-holders** (Running model Pods) and the node's card capacity.
- **Per-model in-flight requests**, parsed from the KubeAI controller's own log
  line (`current requests: sum([N])`) — KubeAI exposes no metrics endpoint, but
  it prints this every autoscale interval.

When a model needs a card and none is free, it evicts the **idlest** holder
(longest with `sum==0`, i.e. LRU) by patching that Model's `maxReplicas` to 0.
KubeAI's own autoscaler then scales it to 0 and releases the card; the waiter
schedules. When the pressure clears, the holder's `maxReplicas` is restored.

Why `maxReplicas`, not `spec.replicas`: KubeAI owns `spec.replicas` and rewrites
it every loop, but it clamps its target to `maxReplicas`, so pinning that to 0
sticks. ArgoCD self-heal would otherwise revert the live patch within seconds, so
`apps/scalable-llm-app.yaml` lists Model `spec.maxReplicas`/`spec.replicas` under
`ignoreDifferences`; the git value of `maxReplicas` stays the normal-operation
ceiling the arbiter restores to.

Guards: a holder must be idle ≥ `IDLE_GRACE` (60s) before it's evictable (so a
bursty-but-active client isn't cut off between requests), and an evicted holder
stays pinned ≥ `EVICT_HOLD` (120s) so the freed card is actually taken by the
waiter before it can reclaim. The arbiter talks to the API server directly with
its ServiceAccount token (no kubectl; image is plain `python:alpine`).

> Hardware note: the single p150 officially serves only **Llama-3.1-8B**
> (tenstorrent/tt-inference-server model support matrix). `tt-llama-b` is the
> same model under a second name — a distinct Model that competes for a card,
> which is what the arbiter arbitrates. Swap in genuinely different models here
> once the TT stack supports more on a single Blackhole card.

## Network model

`scalable-llm` is default-deny-ingress (Kyverno-generated). Ingress reaches it
only from: the Gateway (cluster-wide allow), Grafana/Prometheus (cluster-wide
allow), and same-namespace pods (LiteLLM → KubeAI → model Pod). So no
app-specific ingress NetworkPolicy is needed. Egress is open, so reaching the
shared Postgres works; the Postgres *side* allow was added separately.
