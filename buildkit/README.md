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

## Security

The TCP listener is **unauthenticated** (no TLS). Access is restricted at the
network layer instead: `networkpolicy.yaml` (a `CiliumNetworkPolicy`, additive
to the Kyverno-generated default-deny-ingress) allows ingress to `:1234` **only
from the `github-actions-runner-pods` namespace**. If you ever need to reach the
daemon from elsewhere, prefer enabling mTLS over widening the policy.

## Multi-arch

This deploys a single **amd64** `buildkitd`, which builds amd64 images natively.
For arm64:

- **Native:** copy `deployment.yaml`/`service.yaml` to an `arm64` variant
  (`nodeSelector: kubernetes.io/arch: arm64`, `name: buildkitd-arm64`) and set
  `BUILDKIT_REMOTE_ENDPOINT` on the arm64 pool to that service.
- **Emulated:** register binfmt on the nodes (e.g. a `tonistiigi/binfmt`
  DaemonSet) and build with `--platform linux/amd64,linux/arm64`.

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
