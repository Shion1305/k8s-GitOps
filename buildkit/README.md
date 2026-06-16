# BuildKit (daemonless image builds for self-hosted runners)

Rootless [BuildKit](https://github.com/moby/buildkit) daemon used by the GARM
self-hosted runners (`github-actions-runner-pods`) to build and push container
images **without a Docker daemon and without privileged runner pods**.

Runner pods stay clean: they carry only the Docker CLI / `buildx` (from the
actions-runner base image) and talk to this shared `buildkitd` over TCP.
`buildkitd` itself runs rootless (`--oci-worker-no-process-sandbox`, non-root
UID, no `privileged`).

## Architecture

```text
runner pod (github-actions-runner-pods)        buildkit ns
┌───────────────────────────────┐             ┌────────────────────────┐
│ docker buildx build --push     │   tcp:1234  │ buildkitd (rootless)   │
│   (default builder = remote)   ├────────────▶│  - builds the image    │
│ ~/.docker/config.json auth ────┼─(forwarded)─│  - pushes to Harbor ───┼──▶ harbor.shion1305.com
└───────────────────────────────┘             └────────────────────────┘
```

The runner entrypoint registers a default `buildx` builder pointed at this
daemon (`--driver remote`) and runs `docker buildx install`, so `docker build`
and `docker buildx build` transparently execute on the in-cluster BuildKit. The
build/push runs on `buildkitd`; registry credentials are read from the runner's
`~/.docker/config.json` and forwarded over the build session, so the daemon
holds no standing registry credentials.

## Using it from CI (no workflow changes)

Because the runner image pre-configures the remote builder, **build-and-push
workflows run unchanged** on `runs-on: shion1305-amd` / `shion1305-arm`:

```yaml
jobs:
  build:
    runs-on: shion1305-amd
    steps:
      - uses: actions/checkout@v4
      # however the workflow already authenticates to its registry, e.g. a
      # docker login or docker/login-action step, stays the same
      - run: |
          docker buildx build --push \
            -t harbor.shion1305.com/shion1305/<image>:${{ github.sha }} .
```

`docker/build-push-action` (with `push: true`) and `docker build --push` work
the same way — they use the pre-registered default builder.

**What works** (no daemon needed): `docker build` / `docker buildx build` that
build and `--push` in one step.

**What does not work daemonless** (keep these on `ubuntu-latest`):

- building an image then using it locally — `docker run`, a second-step
  `docker push`, or `--load` (no local daemon to load into)
- `services:` / `container:` jobs (the runner requires a daemon at job start)
- a job that explicitly runs `docker/setup-buildx-action` with the **default**
  driver — it creates a `docker-container` builder (needs a daemon) and
  overrides the default. Set `driver: remote`,
  `endpoint: tcp://buildkitd.buildkit.svc.cluster.local:1234` on that step if
  you must keep it.

## Multi-arch

A single `buildkitd` on an amd64 node builds **both** arches:

- `linux/amd64` natively,
- `linux/arm64` via **QEMU emulation**. `binfmt-daemonset.yaml` registers the
  aarch64 `binfmt_misc` handler on the amd64 build nodes, so `buildkitd`
  advertises both platforms and `--platform linux/amd64,linux/arm64` just works.

The cluster's arm64 nodes (a control-plane box, the internal-gateway SPOF, and a
Raspberry Pi) are unsuitable as build hosts, so emulation on the strong amd64
worker is the deliberate choice over a native arm64 builder.

## Security

**Build path is non-privileged.** `buildkitd` runs rootless (non-root UID, no
`privileged`, no added capabilities). It does need `seccomp`/`AppArmor:
Unconfined` to set up its user-namespaced worker — that is *not* a privileged
container, but it does relax syscall/LSM filtering (below PSS Baseline). A
malicious `RUN` therefore tops out at this non-root pod; it cannot reach the node
as root.

**The only privileged component is binfmt registration**, confined to the
one-shot `install` initContainer in `binfmt-daemonset.yaml` (fixed command, no
build input, exits immediately, image digest-pinned). It is *out of the build
path* — a malicious build can never reach it. This is categorically smaller than
DinD, which would run privileged *in* the build path on every build.

**Hardening applied** to limit a malicious `RUN`:

- `automountServiceAccountToken: false` on `buildkitd` — no SA token to abuse
  against the apiserver.
- `egressDeny` to `169.254.169.254/32` — blocks cloud-metadata SSRF.
- TCP listener is **unauthenticated**; reachable only from
  `github-actions-runner-pods` (ingress policy). Prefer mTLS over widening it.

**Still your responsibility:** the runner is shared with the **public**
`k8s-GitOps` repo. Never run untrusted/fork PRs on the self-hosted runners
(require approval for outside collaborators); a fork PR that builds here runs
arbitrary code in this non-privileged—but networked—pod. A full egress
allow-list (registries only) would further curb exfiltration and is a sensible
follow-up.

## Advanced: buildctl directly

The lower-level `buildctl` client is also baked into the runner image for cases
that need explicit cache control or OCI export:

```bash
buildctl --addr tcp://buildkitd.buildkit.svc.cluster.local:1234 \
  build --frontend dockerfile.v0 \
  --local context=. --local dockerfile=. \
  --output type=image,name=harbor.shion1305.com/shion1305/<image>:<tag>,push=true
```

The daemon's local cache is an `emptyDir` and is lost on pod restart; add
`--export-cache type=registry,...` / `--import-cache` (or buildx `--cache-to/-from`)
for persistent cross-build caching.
