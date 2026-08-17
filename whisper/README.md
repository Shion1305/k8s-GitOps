# Whisper

This application serves multilingual `openai/whisper-large-v3` on one
Tenstorrent Blackhole P150 board through the upstream `tt-media-server` API.
The Pod receives its board through the `tenstorrent.com` DRA driver and runs
without a `/dev/tenstorrent` host mount.

## Deployment choices

- The upstream chart is pinned to commit
  `650deab8b8c1cb8314ab672ee61388bc2e22e6cb`. This is chart `0.2.0`, including
  DRA allocation and startup probes; the latest tagged release still contains
  chart `0.1.0` with direct device host mounts.
- One replica requests one `p150` board, leaving the second board available.
- The Pod requests all 8 Gi of the node's configured 1 Gi hugepages. The
  upstream 32 Gi default cannot schedule on this node.
- Model artifacts and compilation caches persist on the selected node under
  `/var/lib/tt-inference-server/cache/whisper-large-v3-p150`.
- The public model is downloaded anonymously. Never add a Hugging Face token
  to `values.yaml`; add a Vault-backed `ExternalSecret` if authenticated Hub
  access becomes necessary.
- The API is reachable only through the WireGuard-backed internal Gateway at
  `https://whisper.i.shion1305.com`.

The API bearer token is generated once by External Secrets Operator. It is not
stored in Git. Retrieve it only into a local shell when needed:

```bash
export WHISPER_API_KEY="$(kubectl -n whisper get secret whisper-api-key \
  -o jsonpath='{.data.password}' | base64 --decode)"
```

## Verify

The first startup downloads model weights and compiles TT-Metal kernels, so it
can take up to 90 minutes. Follow the rollout and DRA allocation:

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
