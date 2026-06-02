# scalable-llm — KubeAI on Tenstorrent Blackhole (PoC)

OpenAI-compatible inference on **Tenstorrent Blackhole** (2 cards meshed) via the
**Tenstorrent vLLM fork**, orchestrated by **KubeAI**, fronted by **LiteLLM**.

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
├── device-plugin.yaml      # generic-device-plugin: 2 cards -> squat.io/tenstorrent:1
├── kubeai-values.yaml      # KubeAI Helm values: resourceProfile + tt-vllm image + hostPath cache patch
├── models/tt-llama.yaml    # KubeAI Model (TEMPLATE — fill from Phase 2)
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

### Phase 2 — build the image and single-container smoke test

Build with containerd tooling and load into the `k8s.io` namespace so kubelet
sees it (or push to a registry the cluster can pull):

```bash
# on s2605
nerdctl build -t REPLACE_ME/tt-vllm:REPLACE_TAG -f Dockerfile .
sudo nerdctl -n k8s.io load -i tt-vllm.tar          # if not using a registry
sudo crictl images | grep tt-vllm

# verify the container talks to BOTH cards as a mesh, OUTSIDE Kubernetes:
sudo nerdctl run --rm \
  --device /dev/tenstorrent/0 --device /dev/tenstorrent/1 \
  --mount type=bind,src=/dev/hugepages,dst=/dev/hugepages \
  --shm-size=<value> -p 8000:8000 \
  REPLACE_ME/tt-vllm:REPLACE_TAG <TT launch: mesh-shape=1x2 ... --model ...>
curl localhost:8000/v1/models
```

**The launch command that works here is the source of truth** for `models/tt-llama.yaml`
(`spec.args`) and the TT cache env var (`spec.env`).

---

## Placeholders to fill before this serves traffic

| Where | Placeholder | Replace with |
|-------|-------------|--------------|
| `kubeai-values.yaml`, `models/tt-llama.yaml` | `REPLACE_ME/tt-vllm:REPLACE_TAG` | the image built in Phase 2 |
| `models/tt-llama.yaml` | `url`, `metadata.name` | real model + TT load method |
| `models/tt-llama.yaml` | `spec.args`, `spec.env` | Phase-2 launch flags + TT cache var |
| `kubeai-values.yaml` | `/cache/tt` mountPath | TT runtime's actual cache dir |

## Secrets (out-of-band, public repo — never commit values)

```bash
# Vault KV v2 mount + LiteLLM master key
vault secrets enable -path=scalable-llm kv-v2
vault kv put scalable-llm/litellm master_key=sk-<random>
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
