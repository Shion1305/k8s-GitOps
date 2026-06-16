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

## Notes

- `min-idle-runners: 0` scales runner pods to zero when no jobs are queued.
- The `kubernetes_amd64` and `kubernetes_arm64` providers use separate provider
  config files so their pods get different `kubernetes.io/arch` node selectors.
- The runner image is pulled from Harbor. The existing cluster-wide
  `harbor-pull-injection` Kyverno policy should inject the `harbor-pull`
  imagePullSecret into runner pods on admission.
