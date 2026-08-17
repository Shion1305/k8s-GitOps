# Tenstorrent operator

The `tt-operator` Argo CD application installs the upstream Tenstorrent
umbrella chart `0.2.0` in `tt-operator-system`. Argo CD owns the Kubernetes
resources; do not install or upgrade this release with an imperative Helm
command.

## Hardware

- Kubernetes node and host: `shion-ubuntu-2605`
- Accelerators: 2x Blackhole P150A
- PCI functions: `0000:01:00.0` and `0000:03:00.0`

## Ownership boundary

Phase 1 deliberately leaves the hardware lifecycle outside Kubernetes:

- TT-KMD is host-managed and currently `2.11.0`.
- Firmware is host-managed and currently `19.6.0.0` on both devices.
- Kubernetes must not replace, rebuild, unload, or upgrade TT-KMD and must not
  flash, reset, or update either device.

The chart therefore enables Node Feature Discovery (NFD), Fabric Manager, the
DRA driver, and the node-local telemetry collector. Driver Manager, JobSet,
kube-pmix, and telemetry's optional central aggregator are disabled. Prometheus
scrapes each collector through the chart's `PodMonitor`.

No `TenstorrentDriverPolicy` or `TenstorrentFirmwarePolicy` belongs in this
phase. The chart's public DRA image is pulled without the subchart's optional
site-specific pull secret.

## Verify

Argo CD and workloads:

```bash
kubectl -n argocd get application tt-operator
kubectl -n tt-operator-system get deploy,ds,pods
kubectl -n tt-operator-system get events --sort-by=.lastTimestamp
```

NFD and DRA:

```bash
kubectl get nodes \
  -l feature.node.kubernetes.io/pci-1200_1e52.present=true \
  -o wide
kubectl get deviceclasses
kubectl get resourceslices
kubectl get resourceslices -o yaml
```

Confirm the ResourceSlice node name, driver, device count, and topology against
the two PCI functions above. The driver's published topology may not be a
one-resource-per-PCI-function model, so inspect its actual attributes before
judging the count.

Telemetry:

```bash
kubectl -n tt-operator-system get podmonitor tt-telemetry -o yaml
kubectl -n tt-operator-system get pods \
  -l app.kubernetes.io/component=collector -o wide
collector=$(kubectl -n tt-operator-system get pods \
  -l app.kubernetes.io/component=collector \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n tt-operator-system port-forward "pod/${collector}" 18080:18080
curl -fsS http://127.0.0.1:18080/metrics | \
  grep -E 'tt_driver_initialized|tt_kmd_info|tt_architecture_info|tt_chip_count'
```

Do not assume metric label layouts. Inspect the emitted metrics and confirm
Blackhole architecture, two discovered chips, and TT-KMD `2.11.0`. Prometheus
is configured to discover PodMonitors in every namespace.

Host state must be checked before and after rollout on `shion-ubuntu-2605`:

```bash
cat /sys/module/tenstorrent/version
tt-smi -s
```

Expected invariants are two healthy P150A devices at `0000:01:00.0` and
`0000:03:00.0`, TT-KMD `2.11.0`, and firmware `19.6.0.0` on both devices.

## DRA smoke test

Do not commit an always-on smoke workload. After the control plane is healthy,
first observe the chart-created class instead of assuming its name:

```bash
kubectl get deviceclasses
kubectl get resourceslices -o yaml
```

Use the observed class name in a temporary `resource.k8s.io/v1`
`ResourceClaim` with one request using `allocationMode: ExactCount` and
`count: 1`. Reference that claim from a short-lived Pod through both
`spec.resourceClaims` and `containers[].resources.claims`. Confirm allocation,
device visibility, and cleanup before repeating with `count: 2` if the
published driver topology supports it.

The following test derives the DeviceClass from its Tenstorrent driver selector
and refuses to proceed unless exactly one matching class is observed:

```bash
TT_DEVICE_CLASS=$(kubectl get deviceclasses -o json | jq -r \
  '[.items[] | select(any(.spec.selectors[]?;
     (.cel.expression // "") | contains("tenstorrent.com")))]
   | if length == 1 then .[0].metadata.name else empty end')
test -n "${TT_DEVICE_CLASS}" || {
  echo "expected exactly one observed Tenstorrent DeviceClass" >&2
  exit 1
}

kubectl apply -f - <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: tt-smoke-one
spec:
  devices:
    requests:
      - name: accelerator
        exactly:
          deviceClassName: ${TT_DEVICE_CLASS}
          allocationMode: ExactCount
          count: 1
---
apiVersion: v1
kind: Pod
metadata:
  name: tt-smoke-one
spec:
  restartPolicy: Never
  resourceClaims:
    - name: accelerator
      resourceClaimName: tt-smoke-one
  containers:
    - name: inspect-device
      image: ubuntu:24.04
      command: ["sh", "-c", "set -eu; ls -la /dev/tenstorrent; sleep 30"]
      resources:
        claims:
          - name: accelerator
EOF

kubectl get resourceclaim tt-smoke-one -o yaml
kubectl get pod tt-smoke-one -o wide
kubectl logs tt-smoke-one
kubectl delete pod tt-smoke-one
kubectl delete resourceclaim tt-smoke-one
```

## Networking and dependency updates

No TT-specific network policy is needed. Same-namespace traffic is allowed,
kube-apiserver and node traffic are allowed cluster-wide, Prometheus traffic
from the `grafana` namespace is already allowed, and egress is not isolated.

Renovate's built-in Argo CD manager treats a chart source without a URL scheme,
such as `ghcr.io/tenstorrent/helm`, as an OCI dependency and tracks
`ghcr.io/tenstorrent/helm/tt-operator`. No custom OCI regex is required.

## Rollback

Move `apps/tt-operator-app.yaml` to `apps/archived/` (or otherwise remove it
through Git) and let the root application delete the child Application. Its
Argo CD resources finalizer prunes the chart-managed resources. Verify that
the namespace workloads, DeviceClass, ResourceSlices, and NFD resources have
gone. NFD `0.18.3`'s invalid post-delete hook is disabled, so also remove its
hardware label if it remains after NFD is gone:

```bash
kubectl label node shion-ubuntu-2605 \
  feature.node.kubernetes.io/pci-1200_1e52.present-
```

Rollback must not remove DKMS state, unload `tenstorrent`, reinstall TT-KMD,
flash firmware, reset a device, or reboot the host. Because phase 1 never owns
TT-KMD or firmware, no driver reinstall or firmware recovery is part of
rollback.

## Follow-up phases

1. Run one-device and, if supported, two-device DRA workload smoke tests.
2. Integrate application workloads with observed ResourceClaims.
3. Evaluate operator-managed TT-KMD as a separately reviewed ownership change.
4. Evaluate firmware compatibility and lifecycle management separately.
5. Add JobSet or PMIx only when multi-node Tenstorrent compute is introduced.
