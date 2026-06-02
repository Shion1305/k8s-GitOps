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
├── models/tt-llama.yaml    # KubeAI Model: Llama-3.1-8B on one p150 card
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

# Pre-create the node-local TT compile/weights cache (mounted by every model Pod)
sudo mkdir -p /var/local-storage/tt-cache && sudo chmod 1777 /var/local-storage/tt-cache
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

Cold-start (`minReplicas: 0`) measurement, latency/throughput baseline, and the
prefix-aware LB question are deferred to Phase 7; the PoC ships warm
(`minReplicas: 1`) so weight load + TT-Metal compile stays off the request path.

## Network model

`scalable-llm` is default-deny-ingress (Kyverno-generated). Ingress reaches it
only from: the Gateway (cluster-wide allow), Grafana/Prometheus (cluster-wide
allow), and same-namespace pods (LiteLLM → KubeAI → model Pod). So no
app-specific ingress NetworkPolicy is needed. Egress is open, so reaching the
shared Postgres works; the Postgres *side* allow was added separately.
