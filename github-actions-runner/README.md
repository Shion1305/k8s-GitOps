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
It runs once against GARM's persistent database. Argo CD ignores later changes
to its completed Pod template, since Kubernetes cannot update a Job template
and recreating the Job would rerun initialization. On a fresh installation,
Argo CD still creates the Job normally.

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

Use this multi-arch image for both amd64 and arm64 pools:

```text
harbor.shion1305.com/shion1305/garm-runner:2.338.1-ubuntu24.04
```

The image is built from GitHub's official self-hosted runner image
`ghcr.io/actions/actions-runner:2.338.1`, which currently provides Ubuntu
24.04 based amd64 and arm64 variants. It adds the GARM-compatible entrypoint
plus common build tools such as Git LFS, Python, Node.js/npm, build-essential,
cmake, zip/unzip, zstd, rsync, and OpenSSH client.

Build and publish it with the `garm-runner - build & push image` GitHub Actions
workflow. On `main`, that workflow publishes:

- `harbor.shion1305.com/shion1305/garm-runner:<commit-sha>`
- `harbor.shion1305.com/shion1305/garm-runner:2.338.1-ubuntu24.04`
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

## Rust CI on GARM

For a private repository using these repository-scoped GARM runners, keep
GitHub's **Run workflows from fork pull requests** setting disabled. A fork can
change a `pull_request` workflow to request a self-hosted runner label, so the
job's `if:` expression and `runs-on` value are not access controls. If fork PR
workflows must run, use GitHub-hosted runners for them or an organization runner
group restricted to selected trusted workflows.

Use `shion1305-ubuntu-2605-rust` for Rust jobs intended for
`shion-ubuntu-2605`. Create that repository's dedicated pool as described
below after the node is Ready. Each ephemeral runner has no persistent Cargo
home, so keep the setup action in the workflow to select Rust and restore the
Cargo cache. Copy this workflow into the Rust repository as
`.github/workflows/rust.yaml`:

```yaml
name: Rust CI

on:
  push:
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  test:
    # Skip fork PRs; add a separate GitHub-hosted job for them if needed.
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: shion1305-ubuntu-2605-rust
    env:
      RUSTUP_TOOLCHAIN: '1.99.1' # Match the repository's rust-toolchain.toml.
    steps:
      - uses: actions/checkout@v7
      - uses: actions-rust-lang/setup-rust-toolchain@v2
        with:
          toolchain: ${{ env.RUSTUP_TOOLCHAIN }}
          cache-bin: 'false'
          cache-on-failure: 'false'
          build-warnings: warn
      - run: cargo test --locked
```

Commit `Cargo.lock` so `--locked` is reproducible and the cache can follow
dependency changes. Match `RUSTUP_TOOLCHAIN` and `rust-toolchain.toml` to the
image's preinstalled 1.99.1 version to avoid a fresh toolchain install. The
setup action also enables `Swatinem/rust-cache`, which saves Cargo downloads
and dependency build output to GitHub's Actions cache. No extra `actions/cache`
step or in-cluster cache service is needed. The first run downloads
dependencies; later runs can restore the Cargo cache. Caches are scoped to one
repository and accessible branches, not shared across repositories. GitHub's
default cache limit is 10 GB per repository, and entries unused for seven days
expire. The shared `shion1305-amd` and `shion1305-arm` images still have no
preinstalled Rust; choose them only when you intend to test those generic
runners.

For a Rust project under a monorepo subdirectory, set the action's workspace
and the Cargo step's working directory together. If `rust-toolchain.toml` is
inside that subdirectory, set `RUSTUP_TOOLCHAIN` to the same version at job
level and pass it to the setup action. The cache action queries `rustc` from
the repository root, where a subdirectory's toolchain file does not apply on
a fresh self-hosted runner. Passing `toolchain` makes the action install Rust
with its minimal profile, rather than auto-installing rustup's default profile:

```yaml
jobs:
  test:
    runs-on: shion1305-ubuntu-2605-rust
    env:
      RUSTUP_TOOLCHAIN: '1.99.1' # Match services/api/rust-toolchain.toml.
    steps:
      - uses: actions/checkout@v7
      - uses: actions-rust-lang/setup-rust-toolchain@v2
        with:
          toolchain: ${{ env.RUSTUP_TOOLCHAIN }}
          rust-src-dir: services/api
          cache-workspaces: services/api -> target
          cache-bin: 'false'
      - run: cargo test --locked
        working-directory: services/api
```

`cache-workspaces` also accepts multiple newline-separated
`workspace -> target` entries. `rust-src-dir` selects the Rust source directory
for version reporting; keep the lockfile in that Cargo workspace. Keep the job
toolchain version in sync with its `rust-toolchain.toml`.

The manual [Rust runner smoke workflow](../.github/workflows/rust-runner-smoke.yaml)
builds a small locked crate on the one GARM pool selected at dispatch. Its
default is the dedicated 2605 pool; the generic amd64 or arm64 pool runs only
when explicitly selected. Run it twice after runner or cache changes and
compare toolchain setup, cache restore, and total job times.

### Dedicated Rust amd64 pool on shion-ubuntu-2605

The dedicated image has Rust 1.99.1 already installed. Its
[Dockerfile](runner-image-rust/Dockerfile) copies the
minimal toolchain from a digest-pinned official Rust image into a digest-pinned
GARM runner image. The toolchain stays under `/usr/local`: the GARM entrypoint
copies `/home/runner` into a fresh `/runner` volume at every start, so putting
the toolchain there would repeat the large copy on every ephemeral Pod.
`rustfmt` and `clippy` are added to the image because the ISUCON Rust CI uses
both. The image workflow builds amd64 on a GitHub-hosted runner.

Publish with the
[`garm-runner-rust - build & push image`](../.github/workflows/build-garm-rust-runner-image.yaml)
workflow. Its run summary prints the immutable
`harbor.shion1305.com/shion1305/garm-runner-rust@sha256:...` reference. Update
the GARM base digest in the Rust Dockerfile when publishing a new generic
runner base. Put the published Rust image reference in the local
`GARM_RUST_2605_RUNNER_IMAGE` setting. Once `shion-ubuntu-2605` is Ready,
register each repository and create its Rust pool:

```bash
cd github-actions-runner
just repo-add k8s-GitOps # Omit if the repository is already registered.
just pool-add-ubuntu-2605-rust k8s-GitOps
```

The recipe requires the dedicated Rust image at an immutable digest, verifies
that the node is Ready, sets `min-idle-runners` to 0 and `max-runners` to 1
initially, and gives the pool only the `shion1305-ubuntu-2605-rust` label.
Its GitOps-managed GARM provider has hard amd64 and hostname selectors for
`shion-ubuntu-2605`; jobs wait if that node is unavailable and never move to
`shion-ubuntu-2505`. GARM pools themselves are created through `garm-cli`, as
with the generic pools. A repository that requests a different Rust version
can still install it through `rustup`, but the preinstalled version saves setup
time only when it matches that repository's `rust-toolchain.toml`.

The private `Shion1305/isucon2026-problem` pool is deliberately sized to
`max-runners=3` and `min-idle-runners=3` after repository onboarding. Its fork
PR workflow execution is disabled. These three ready Pods are pinned to 2605;
each requests 500m CPU and 2 GiB memory, with a 16 GiB memory limit. This
reserves 1.5 CPU and 6 GiB memory while idle and caps the three runners at
48 GiB in total. The public `k8s-GitOps` smoke pool remains at `min-idle=0`.
The three-job overlap has not been benchmarked, so watch node CPU and I/O
pressure as normal CI traffic begins.

After confirming the private repository still has fork PR workflows disabled,
apply this sizing only to its dedicated Rust pool:

```bash
just pool-list # Find the ISUCON 2605 Rust pool ID.
just cli pool update <isucon-pool-id> --enabled --max-runners 3 --min-idle-runners 3
just pool-audit
```

On 2026-10-31, prewarmed 2605 runners ran the same ISUCON Rust checks with
Rust 1.99.1. These are single-job measurements, not concurrent throughput:

| Cargo cache choice | First job | Repeat job | Cache transfer |
| --- | ---: | ---: | --- |
| No Cargo cache | 46 s | Not measured | None |
| Registry-only cache | 54 s | 69 s | 43.7 MB; repeat restore 21 s |
| Registry plus build output | 160 s | 233 s | 561 MB; repeat restore 212 s |

Installing the already-present toolchain took about 1-2 seconds. An on-demand
runner added about 50 seconds of provisioning before the job; a prewarmed
runner started the job after roughly 2-3 seconds. For this repository, the
measured full rebuild was quicker than transferring the Cargo cache, so its
permanent Rust CI uses the preinstalled toolchain without the cache action.
Other repositories can use the generic cached workflow above when dependency
compilation costs more than the transfer.

Select `shion1305-ubuntu-2605-rust` in the manual smoke workflow after the
new image and pool are ready. It verifies the preinstalled compiler before
calling the setup action. Compare toolchain setup, image pull and Pod startup,
cache restore, and node disk usage with a deliberately selected generic pool.

Rust code compiled **inside a container build** uses a separate cache path.
The [Harbor build action](../.github/actions/harbor-build-push/action.yml)
imports `${image}:buildcache` when `push: true` and exports it on default-branch
pushes. PR builds configured with `push: false` do not currently import it.
The registry cache persists BuildKit image layers across ephemeral builders.
Place dependency compilation in a Dockerfile layer before copying frequently
changed source so the registry cache can reuse it. Cargo files written only
to a Dockerfile `RUN --mount=type=cache` mount are not included in the exported
registry cache; the host-side Rust Actions cache is not available inside that
build.

## Pool Sizing

Pools are configured **imperatively** through `garm-cli`, so nothing in this
repository prevents their sizing from drifting. `just pool-audit` reports pools
that exceed the general ceilings (`max_runners <= 8`, `min_idle_runners <= 1`)
and exits non-zero. It allows at most 3/3 only for the private ISUCON pool on
the dedicated 2605 Rust provider, with the exact runner label and a digest
pinned Rust image.

Outside that scoped pool, keep `min_idle_runners` at 0, or at most 1 for a
repository with continuous CI traffic. **Idle runners are not free.** Every
idle runner is a *fresh pod* whose image must be pulled and unpacked before
the runner can register, and:

- The generic providers use `imagePullPolicy: Always`, so each cold start goes
  back to Harbor. The dedicated 2605 provider uses `IfNotPresent` with an
  immutable image digest, so replacement Pods can reuse the local image.
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
