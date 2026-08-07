# GARM GitHub Actions Runners

This directory deploys [GARM](https://github.com/cloudbase/garm) with
`mercedes-benz/garm-provider-k8s` so GARM can create ephemeral GitHub Actions
runner pods in this cluster.

## Scope

GitHub does not provide a personal-account-wide self-hosted runner scope.
GARM works around that by registering each repository as a GARM repository entity
and installing a `workflow_job` webhook for that repository. Add each
`Shion1305/<repo>` repository you want to use.

## Vault Secret

Create the Vault secret before syncing this app:

```bash
vault kv put github-app-shared/garm \
  database_passphrase="$(openssl rand -base64 48 | tr -dc A-Za-z0-9 | head -c 32)" \
  jwt_secret="$(openssl rand -base64 48)" \
  admin_username="admin" \
  admin_password="<replace-me>" \
  admin_email="<replace-me>" \
  github_app_id="<app-id>" \
  github_app_installation_id="<installation-id>" \
  github_app_private_key=@private-key.pem
```

The GitHub App must be installed on the repositories you want GARM to manage and
needs these permissions:

- Repository Administration: read/write
- Repository Metadata: read-only
- Repository Webhooks: read/write

## Initial Login

The `garm-init` Job creates the first admin user and writes the controller URLs.
After it succeeds, open:

```text
https://garm.i.shion1305.com
```

Only the webhook endpoint is exposed on the public Gateway:

```text
https://garm.shion1305.com/webhooks
```

You can also use the CLI inside the server pod:

```bash
kubectl exec -n github-actions-runner deploy/garm-server -- /opt/garm/bin/garm-cli --help
```

## Runner Image

Use this fixed multi-arch image for both amd64 and arm64 pools:

```text
harbor.shion1305.com/shion1305/garm-runner:2.335.1-ubuntu24.04
```

The image is built from GitHub's official self-hosted runner image
`ghcr.io/actions/actions-runner:2.335.1`, which currently provides Ubuntu
24.04 based amd64 and arm64 variants. It adds the GARM-compatible entrypoint
plus common build tools such as Git LFS, Python, Node.js/npm, build-essential,
cmake, zip/unzip, zstd, rsync, and OpenSSH client.

Build and publish it with the `garm-runner - build & push image` GitHub Actions
workflow. On `main`, that workflow publishes:

- `harbor.shion1305.com/shion1305/garm-runner:<commit-sha>`
- `harbor.shion1305.com/shion1305/garm-runner:2.335.1-ubuntu24.04`
- `harbor.shion1305.com/shion1305/garm-runner:latest`

This is close to the GitHub official self-hosted runner environment, but it is
not a full clone of GitHub-hosted `ubuntu-latest` VM images. The Docker CLI and
buildx are present from the official base image, but these Kubernetes runner
pods do not include a Docker daemon by default.

## Add Repositories

Local operational commands live in `Justfile` and read defaults from `.env`.
The local `.env` is ignored by Git; `.env.example` is the tracked template.
Secrets stay in the `garm-server` pod via Kubernetes Secret environment
variables.

Run this once after the `garm-init` Job has completed. The private key is
mounted from the Kubernetes Secret only for copying into GARM's encrypted
database:

```bash
cd github-actions-runner
just init-github
```

Then register a repository and add both amd64/arm64 pools. The repository
argument is required.

```bash
just bootstrap-repo k8s-GitOps
```

If the repository is under `GARM_OWNER` from `.env` (`Shion1305` by default),
pass only the repository name:

```bash
just bootstrap-repo another-repo
```

For a different owner or organization, pass `owner/repo`:

```bash
just bootstrap-repo Shion1305Dev/another-repo
```

Workflows can then target:

```yaml
runs-on: shion1305-amd
```

or:

```yaml
runs-on: shion1305-arm
```

## Pool Sizing

Pools are configured **imperatively** through `garm-cli`, so nothing in this
repository prevents their sizing from drifting. `just pool-audit` reports pools
that exceed the safe ceilings (`max_runners <= 8`, `min_idle_runners <= 1`) and
exits non-zero, which makes it usable as a check.

Keep `min_idle_runners` at 0, or at most 1 for a repository with continuous CI
traffic. **Idle runners are not free.** Every idle runner is a *fresh pod* whose
image must be pulled and unpacked before the runner can register, and:

- `imagePullPolicy: Always` (set in `configmap.yaml`) means each cold start goes
  back to Harbor rather than reusing a cached layer.
- kubelet pulls images **one at a time per node** (`serializeImagePulls` defaults
  to true), so N idle runners become N serialized pulls on whichever node the
  scheduler picked.
- The scheduler's `ImageLocality` score actively concentrates runners on the node
  that already cached the image. `topologySpreadConstraints` in `configmap.yaml`
  counteracts that, but it is a soft constraint and only spreads so far.

The cost is therefore `min_idle_runners x image_size` of pull-and-unpack work
per node, repeated every time a runner is consumed and replaced. For a pool on a
multi-gigabyte image that is enough to saturate a node's disk.

### Pools on large or mutable images

`Shion1305/crypto-auto-trading` (amd64) does not use the shared
`garm-runner` image; it uses its own ~1.2 GB `crypto-auto-trading-ci:latest`.
For pools like this, prefer a pinned tag over `:latest` where possible, and keep
`min_idle_runners` at 0-1. See the incident note under
[Runners stuck in ContainerCreating](#runners-stuck-in-containercreating).

## Observability

GARM exposes Prometheus metrics on `garm-server:9997/metrics`. The `[metrics]`
block in `deployment.yaml` sets `disable_auth = true`, so `/metrics` is scraped
without a bearer token — only that endpoint is unauthenticated; the `/api/v1`
surface keeps its JWT auth. This is deliberate: GARM's metrics token expires and
would silently stop scraping, and the endpoint is reachable only in-cluster
(default-deny ingress + the clusterwide `allow-from-infra` policy admit only
Prometheus, Envoy, nodes, and runner-pods to port 9997).

- `servicemonitor.yaml` scrapes `/metrics` and pins `job="garm"`. The primary
  Prometheus discovers it automatically.
- Dashboard: **GitHub Actions Runners** folder in Grafana
  (`grafana-folder.yaml` + `grafana-dashboard.yaml`, uid `garm-runners`) —
  controller health, runners by repo/status/arch, workflow jobs, pool sizing,
  GitHub API rate-limit/error ratios, webhook validity, and runner-pod
  CPU/memory.

Key metric families: `garm_health`, `garm_runner_status`, `garm_job_status`,
`garm_pool_*`, `garm_runner_operations_total`, `garm_github_operations_total` /
`garm_github_errors_total`, `garm_github_rate_limit_*`, `garm_webhook_received`.

## Troubleshooting

### Runners stuck in ContainerCreating

Symptom: many `garm-*` pods sit in `ContainerCreating` for 5-15 minutes, pods
that are deleted linger in `Terminating`, and unrelated workloads scheduled to
the same node are slow to start too.

This is almost always **image-pull starvation on one node**, not a GARM fault.
Confirm before changing anything:

```bash
# 1. Is the pod just waiting on its image? Compare the two numbers -- a large
#    "including waiting" with a small actual pull time means queue starvation.
kubectl describe pod -n github-actions-runner-pods <pod> | tail -20
# -> Successfully pulled image "..." in 619ms (10m13s including waiting)

# 2. Is the node I/O-bound? `full` is the share of time ALL tasks were stalled.
kubectl get --raw "/api/v1/nodes/<node>/proxy/stats/summary" \
  | jq '.node.io.psi.full, .node.cpu.psi.full'

# 3. How slow are that node's pulls, compared with a healthy node?
kubectl get --raw "/api/v1/nodes/<node>/proxy/metrics" \
  | grep 'runtime_operations_duration_seconds_.*pull_image'
# sum/count is the average seconds per pull.

# 4. Which pools are oversized?
just pool-audit
```

A healthy node averages a couple of seconds per pull with I/O pressure in the
single digits. Tens of seconds per pull with `io.psi.full` above ~50% means the
node's container filesystem is the bottleneck, and every pod scheduled there —
runner or not — pays for it.

Recovery, in order:

1. `just pool-audit`, then shrink any oversized pool:
   `just cli pool update <id> --max-runners 6 --min-idle-runners 1`.
2. Delete the runners that never registered. Only ever delete instances whose
   `runner_status` is `pending`; `active` ones may be executing a job:
   `just cli runner list --format json` then
   `just cli runner delete <name> -f`.
3. Let the node drain. Teardown is itself I/O work, so `Terminating` pods clear
   slowly while pressure is still high.

**2026-07-29 incident.** The `crypto-auto-trading` amd64 pool had drifted to
`min_idle_runners: 8` / `max_runners: 20` on the ~1.2 GB
`crypto-auto-trading-ci:latest` image. All of those pods landed on
`shion-ubuntu-2605`, whose write-saturated root SSD (see below) sustains only
~25 MB/s and left the node I/O-stalled ~75% of the time; pulls there averaged
~50 s versus ~1.5 s on `shion-ubuntu-2505`, a 33x gap on identical images.
Runners could not register inside the 20-minute bootstrap
timeout, so GARM reaped and recreated them, which fed the queue further.
Collateral damage reached unrelated workloads — an `atc-executor` pod spent
12m46s waiting on its image. Fixes: pool resized to 6/1, stuck runners deleted,
and `topologySpreadConstraints` added to `configmap.yaml`.

### Node-level follow-ups

These are **not** applied by this repository because they need node-level
changes, but they are what actually caps runner throughput.

**`shion-ubuntu-2605`'s root SSD is write-saturated, not worn out.** Everything
— `/`, `/var/lib/containerd`, `/var/lib/kubelet`, and therefore every runner's
`emptyDir` workspace — lives on a single 2 TB `SPCC M.2 PCIe SSD`
(`/dev/nvme0n1p2`). Its SMART data:

| Metric | Value | Reading |
| --- | --- | --- |
| Percentage Used | 0% | not worn out |
| Media/Data Integrity Errors | 0 | not failing |
| Data Units Written | 39.6 TB over 1,177 power-on hours | ~34 GB/h sustained |
| Controller Busy Time | 1,178 h of 1,177 h powered on | **never idle** |

Controller busy time equalling power-on time is the finding. A DRAM-less
consumer drive that never gets idle time cannot run garbage collection, so its
fast-write cache stays exhausted and it degrades to its slowest write path.
That shows up as ~25 MB/s of sustained writes and NVMe command timeouts in
`dmesg`:

```text
nvme nvme0: I/O tag 30 (d01e) opcode 0x1 (I/O Cmd) QID 1 timeout, aborting req_op:WRITE(1) size:262144
```

A 30-second write timeout on an NVMe device stalls containerd, which is why pod
teardown (`stop_podsandbox`) and pod startup fail together. Replacing the drive
without reducing the write volume would only postpone this. Worth pursuing:
give CI workspaces a separate volume rather than the node root disk, and check
what else on this node writes continuously.

**kubelet serializes image pulls.** `serializeImagePulls` defaults to true, so
one slow pull blocks every other pod's start on that node — including pods that
have nothing to do with CI. Setting `serializeImagePulls: false` with
`maxParallelImagePulls: 3-5` in the node's kubelet config would contain the
blast radius.

## Notes

- `min-idle-runners: 0` scales runner pods to zero when no jobs are queued.
- The `kubernetes_amd64` and `kubernetes_arm64` providers use separate provider
  config files so their pods get different `kubernetes.io/arch` node selectors.
- The runner image is pulled from Harbor. The existing cluster-wide
  `harbor-pull-injection` Kyverno policy should inject the `harbor-pull`
  imagePullSecret into runner pods on admission.
