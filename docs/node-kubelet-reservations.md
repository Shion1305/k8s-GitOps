# Node Kubelet Memory / CPU Reservations

This document tracks per-node kubelet resource reservations (`systemReserved`,
`kubeReserved`, `evictionHard`, `enforceNodeAllocatable`). It is the
standing reference for what each node **should** have configured, kept in
sync with what is actually deployed.

> **Why these settings matter**: without reservations, the kubepods cgroup is
> effectively unbounded. Pods can grow until the host hits a global OOM,
> which kills system processes (kubelet, sshd, containerd) instead of
> individual pods. With reservations, pod-level cgroup eviction triggers
> first, keeping the node responsive. See incident postmortems in
> `docs/ops/` (gitignored) for concrete failure modes.

---

## Current values

All values are applied directly to `/var/lib/kubelet/config.yaml` on each
node. This is **outside GitOps** — re-apply on node rebuild. See
[Persistence caveat](#persistence-caveat).

| Node | Role | RAM | hugepages-2Mi | systemReserved (cpu / mem) | kubeReserved (cpu / mem) | evictionHard.memory.available | Pod allocatable mem | Status |
|---|---|---|---|---|---|---|---|---|
| `instance-k8s-proxy` | worker | 12 GiB | 0 | 200m / 500Mi | 200m / 500Mi | 300Mi | ~10.38 GiB | applied 2026-05-09 |
| `shion-ubuntu-2505` | worker | 32 GiB | 2 GiB | 500m / 1Gi | 500m / 1Gi | 500Mi | ~26.6 GiB | applied 2026-05-10 |
| `instance-2024-1` | control-plane | 12 GiB | 0 | — | — | — | ~11.55 GiB (no enforcement) | **not applied** |
| `raspi-cm4` | worker (`SchedulingDisabled`) | 8 GiB | 0 | — | — | — | ~7.53 GiB (no enforcement) | not applicable |

### Why `instance-2024-1` is not yet covered

Control-plane nodes also need reservations for etcd, kube-apiserver,
kube-controller-manager, and kube-scheduler. Adding only `systemReserved` /
`kubeReserved` without sizing those components risks evicting them under
pressure. Defer until a control-plane sizing review is done.

### Why `raspi-cm4` is not covered

Currently `SchedulingDisabled`. No pods are scheduled here, so kubepods
cgroup pressure cannot occur. If it is ever re-enabled, apply:

| systemReserved | kubeReserved | evictionHard | Pod allocatable |
|---|---|---|---|
| 200m / 300Mi | 200m / 300Mi | 200Mi | ~6.81 GiB |

---

## Common configuration block

The structure applied to every covered node is identical; only the values
differ:

```yaml
# /var/lib/kubelet/config.yaml (excerpt)
systemReserved:
  cpu: <value>
  memory: <value>
kubeReserved:
  cpu: <value>
  memory: <value>
evictionHard:
  memory.available: <value>
  nodefs.available: 10%
  imagefs.available: 15%
enforceNodeAllocatable:
- pods
```

`enforceNodeAllocatable: [pods]` is what actually sets the cgroup
`memory.max` on `kubepods.slice`. Without it, the reservation values are
informational only and do not enforce a hard cap.

---

## Sizing methodology

Pod allocatable is computed by the kubelet as:

```
allocatable = capacity - hugepages - systemReserved - kubeReserved - evictionHard
```

The resulting `kubepods.slice/memory.max` ends up slightly above
`allocatable` because eviction is *soft* relative to the cgroup max — the
kubelet evicts pods *before* the cgroup OOM kicks in. Concretely:

```
kubepods.memory.max ≈ capacity - hugepages - systemReserved - kubeReserved
```

(i.e., evictionHard is a kubelet-side threshold, not a cgroup limit.)

### Recommended scale

| Total RAM | systemReserved mem | kubeReserved mem | evictionHard.memory |
|---|---|---|---|
| 8 GiB | 300Mi | 300Mi | 200Mi |
| 12 GiB | 500Mi | 500Mi | 300Mi |
| 32 GiB | 1Gi | 1Gi | 500Mi |
| 64+ GiB | 2Gi | 2Gi | 1Gi |

CPU reservations scale with vCPU count: 100m–200m per kind on small nodes
(≤4 vCPU), 500m on larger nodes. Set higher if specific system workloads
(e.g., GitHub Actions runners, GUI sessions) need guaranteed slices.

---

## Apply procedure

```bash
# 1. backup
ssh <node> 'sudo cp /var/lib/kubelet/config.yaml \
  /var/lib/kubelet/config.yaml.bak-$(date +%Y%m%d-%H%M%S)'

# 2. patch via Python YAML (safer than sed for nested keys)
ssh <node> 'sudo python3 -c "
import yaml
p = \"/var/lib/kubelet/config.yaml\"
with open(p) as f:
    cfg = yaml.safe_load(f)
cfg[\"systemReserved\"] = {\"cpu\": \"<X>\", \"memory\": \"<Y>\"}
cfg[\"kubeReserved\"] = {\"cpu\": \"<X>\", \"memory\": \"<Y>\"}
cfg[\"evictionHard\"] = {
    \"memory.available\": \"<Z>\",
    \"nodefs.available\": \"10%\",
    \"imagefs.available\": \"15%\",
}
cfg[\"enforceNodeAllocatable\"] = [\"pods\"]
with open(p, \"w\") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=True)
"'

# 3. restart kubelet (node briefly NotReady, ~5s)
ssh <node> 'sudo systemctl restart kubelet'

# 4. verify
kubectl describe node <node> | grep -A8 'Allocatable:'
ssh <node> 'cat /sys/fs/cgroup/kubepods.slice/memory.max'
```

### Rollback

```bash
ssh <node> 'sudo cp /var/lib/kubelet/config.yaml.bak-<timestamp> \
  /var/lib/kubelet/config.yaml && sudo systemctl restart kubelet'
```

---

## Persistence caveat

These edits are **not** managed by GitOps. They live only on each node's
disk. They will be lost if:

1. The node is re-joined via `kubeadm join` (the join templates from
   `kubeadm-config` ConfigMap, which doesn't carry these values).
2. The OS is reinstalled or `cloud-init` runs again.

When rebuilding a node, consult this document and re-apply.

### Future: making it durable

Three viable paths, none implemented yet:

- **A. Cluster-wide `kubeadm-config`**: put the values into the
  `kubeletConfiguration` section and run `kubeadm upgrade node phase
  kubelet-config` per node. Issue: same values for all nodes, but our
  nodes range from 8 GiB to 32 GiB.
- **B. Per-node systemd drop-in**: `/etc/systemd/system/kubelet.service.d/20-reservations.conf`
  with `--system-reserved=...` flags. Issue: diverges from kubeadm's
  config-file flow.
- **C. Ansible / cloud-init**: declarative per-node config, GitOps-friendly.
  Issue: introduces a new tool.

For now, this document is the source of truth.

---

## Related

- `docs/ops/` (gitignored): incident postmortems that motivated these
  reservations — `k8s-proxy-oom-incident-2026-05-09.md`,
  `shion-ubuntu-2505-oom-incident-2026-05-10.md`,
  `kubelet-memory-reservation-2026-05-09.md` (initial setup record).
