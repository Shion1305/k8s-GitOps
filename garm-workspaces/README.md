# GARM workspaces on shion-ubuntu-2605

This app deploys a dedicated Rancher local-path provisioner (v0.0.37) and the
nondefault `garm-2605-workspace` StorageClass. It can provision only on
`shion-ubuntu-2605`, under `/var/lib/garm-workspaces/volumes` on that node's
SATA SSD. Other nodes have an explicit empty fallback path list. The
provisioner and helper Pods are also pinned to 2605. The controller has only
the Kubernetes permissions needed to manage its helper Pods and PVs; the
short-lived helper Pods do not mount ServiceAccount tokens.

The StorageClass uses `WaitForFirstConsumer`, a node-affined `local` PV, and
`Delete` reclaim policy. A GARM runner Pod can later define a `runner` volume
with a generic ephemeral PVC, which replaces the provider's default
`emptyDir` at `/runner`. Kubernetes then owns the PVC for that Pod and removes
it when the Pod is deleted. The provisioner removes its unique PV directory.
This is disposable CI workspace storage, not persistent build cache. Runner
image layers and other Pods remain on their existing storage.
The helper timeout is 300 seconds to allow large workspace trees to be
removed; check deletion latency during the first busy rollout.

## Disk guard

The [Ansible host preparation](https://github.com/Shion1305/ansible-k8s-infra)
must mount the expected SATA filesystem at `/var/lib/garm-workspaces` and
create `/var/lib/garm-workspaces/volumes/.garm-ssd-ready` **on that mounted
filesystem** only after checking its UUID. The marker must be root-owned,
mode `0444`, with exact content `garm-workspaces-s2605-v1\n`; the `volumes`
directory must be root-owned, mode `0755`. The setup and teardown helpers
reject a missing or changed marker, an unexpected parent directory, a symlink,
or a PV path outside a single generated directory in
`github-actions-runner-pods`. If the SSD is absent, provisioning fails instead
of writing CI files to the root filesystem. Deletion also stops until the
expected SSD is available again.

The 16 GiB PVC request used by the later runner Pod template is **not a hard
disk quota**. Local-path creates ordinary directories; it does not reserve or
limit bytes on the 465 GiB SSD. At 20 concurrent runner Pods, requests total
320 GiB, but one job can exceed its request and fill the disk. Track actual
free space and I/O pressure; consider a filesystem quota implementation before
relying on enforced per-job limits.

## Staged rollout

1. Apply and verify the reviewed Ansible disk preparation. Check the expected
   UUID, mount source, free space, and marker on 2605. Do not install the
   StorageClass before the disk is ready.
2. Sync this `garm-workspaces` app. Confirm its controller is Ready on 2605 and
   `garm-2605-workspace` exists without the default-class annotation. Existing
   GARM runners still use `emptyDir` at this stage.
3. Apply the [disposable canary Pod](examples/canary-pod.yaml) manually. It
   creates one generic ephemeral claim and writes 64 MiB as UID 1001. Confirm
   the Pod is on 2605, the PVC is Bound, its PV has a `spec.local.path` under
   `/var/lib/garm-workspaces/volumes`, and `stat -c %d /runner` in the Pod
   matches `stat -c %d /var/lib/garm-workspaces/volumes` on the host. Inspect
   its logs and time from Pod creation to Running. The helper lifecycle test
   in CI covers missing-marker and path-rejection cases without unmounting
   or touching the live SSD.
4. Delete the canary Pod. Wait for its generated PVC, PV, and PV directory to
   disappear; confirm the root-owned marker and an unrelated directory remain.
   Investigate any stuck finalizer or helper error before changing GARM.
5. In a separate change, add a `runner` generic ephemeral PVC to only the
   2605 GARM provider Pod template, with `storageClassName:
   garm-2605-workspace`. Check a newly created GARM Pod has that volume and
   that its `/runner` device matches the SATA filesystem. Monitor job startup,
   workspace writes, free space, and Pod/PVC cleanup. The amd64 generic and
   arm64 providers keep their current `emptyDir` volumes.

The canary manifest is excluded from this app's Kustomize resources, so Argo CD
never recreates the test Pod. Run it only after the host mount and app are
healthy, then delete it explicitly.
