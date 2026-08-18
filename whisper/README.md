# Whisper

This application serves multilingual `openai/whisper-large-v3` on one
Tenstorrent Blackhole P150 board through the upstream `tt-media-server` API.
The Pod receives its board through the `tenstorrent.com` DRA driver and runs
without a `/dev/tenstorrent` host mount.

## tt-operator integration

`tt-operator` is a separate, cluster-scoped prerequisite rather than the owner
of the Whisper Deployment. It publishes the `tenstorrent.com` DeviceClass and
per-node ResourceSlices, runs the DRA kubelet plugin, and uses Fabric Manager to
enumerate boards. The inference chart then creates a `ResourceClaimTemplate`
that selects `boardName == "p150"` with `ExactCount: 1`; every Whisper Pod gets
one generated claim and the DRA driver injects only its allocated device node.

The Application is assigned Argo CD sync wave 10 so its child Application is
registered after the wave-0 `tt-operator` Application. Sync waves do not wait
for resources managed by that child Application to become healthy; the
workload therefore also relies on Kubernetes scheduling to wait until the DRA
driver and a matching DeviceClass are ready. Its only host paths are the
model/compile cache and the node's 1 Gi hugepage filesystem; accelerator access
is exclusively DRA.

Argo CD repo-server has Git submodule initialization disabled cluster-wide.
The pinned upstream repository contains unrelated private/SSH submodules, but
the inference chart itself does not use them. Keep the chart source pinned and
do not grant repo-server credentials for those unrelated repositories.

## Deployment choices

- The upstream chart is pinned to commit
  `650deab8b8c1cb8314ab672ee61388bc2e22e6cb`. This is chart `0.2.0`, including
  DRA allocation and startup probes; the latest tagged release still contains
  chart `0.1.0` with direct device host mounts.
- One replica requests one `p150` board, leaving the second board unallocated
  by DRA. The Pod reserves the node's full hugepage pool, however, so another
  hugepage-dependent Tenstorrent workload cannot run concurrently.
- The Pod requests all 8 Gi of the node's configured 1 Gi hugepages. The
  upstream 32 Gi default cannot schedule on this node.
- Model artifacts and compilation caches persist on the selected node under
  `/var/lib/tt-inference-server/cache/whisper-large-v3-p150`. `HF_HOME` points
  into that mount, so partial Hugging Face downloads survive container
  restarts and subsequent starts can reuse the downloaded weights.
- The model-specific startup deadline is 12 hours. This accommodates unusually
  slow Hugging Face transfers without repeatedly restarting the container;
  downloads that exceed one attempt still resume from the persistent cache.
- The public model is downloaded anonymously. Never add a Hugging Face token
  to `values.yaml`; add a Vault-backed `ExternalSecret` if authenticated Hub
  access becomes necessary.
- The API is reachable only through the WireGuard-backed internal Gateway at
  `https://whisper.i.shion1305.com`.

The API bearer key lives at Vault path `whisper/api`, property `api-key`, and is
materialized by External Secrets Operator. Before the first sync, enable the
dedicated KV v2 mount, write a generated key, and apply the scoped ESO policy
and Kubernetes auth role:

```bash
vault secrets enable -path=whisper kv-v2
vault kv put whisper/api api-key=<generated-api-key>
bash vault/scripts/setup-eso-policies.sh
```

Never place the key in Git or command output captured in CI. Retrieve it from
the documented Vault path only into a local shell when making a request:

```bash
export WHISPER_API_KEY="$(vault kv get -field=api-key whisper/api)"
```

## Verify

The first startup downloads roughly 3.1 GB of model weights and compiles
TT-Metal kernels. Under a slow Hugging Face connection this can take many
hours; the startup probe allows 12 hours per attempt and partial downloads are
retained between attempts. Follow the rollout and DRA allocation:

```bash
kubectl -n argocd get application whisper
kubectl -n whisper get deploy,pods,resourceclaims
kubectl -n whisper describe pod -l app.kubernetes.io/name=tt-inference-server
kubectl get resourceslices
kubectl -n whisper logs deploy/whisper -f
curl -fsS https://whisper.i.shion1305.com/tt-liveness
```

Transcribe an audio file:

```bash
curl --fail-with-body https://whisper.i.shion1305.com/v1/audio/transcriptions \
  -H "Authorization: Bearer ${WHISPER_API_KEY}" \
  -F file=@<audio-file> \
  -F response_format=verbose_json
```

Verify that the generated `ResourceClaim` allocated exactly one of `tt-0` or
`tt-1`, then compare hardware state before and after the rollout:

```bash
kubectl -n whisper get resourceclaims -o yaml
cat /sys/module/tenstorrent/version
tt-smi -s
```

The expected invariants remain TT-KMD `2.11.0` and firmware `19.6.0.0` on both
P150A devices. This application does not install a driver manager or firmware
policy and must not reset either board.

## Rollback

Remove or archive `apps/whisper-app.yaml` and let Argo CD delete the inference
workload before changing or removing `tt-operator`. Confirm that the Pod and
its generated `ResourceClaim` are gone. The node-local model cache is
intentionally retained because it is rebuildable and makes a rollback/redeploy
faster; remove it manually only when disk reclamation is required.
