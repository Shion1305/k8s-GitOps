# Composite action: build & push to Harbor

This guide is for **consumers** of the GitHub composite action that pushes
container images to `harbor.shion1305.com`. The action source itself is
[`action.yml`](./action.yml) in this directory.

## Why this exists

Pushing to a private Harbor registry from CI normally requires long-lived
robot-account credentials in GitHub repo Secrets. That has three real
problems: rotation requires touching every consumer repo, anyone with repo
Settings can read the secret name back into a workflow they author, and
there is no central audit trail. This action eliminates the GitHub-side
credential entirely — each run exchanges its short-lived (~10 min) GitHub
OIDC token for the robot creds at job start, with Vault as the authority.

## Why a composite action and not a reusable workflow

This used to live at `.github/workflows/harbor-build-push.yaml` as a
reusable workflow. It needed `crane` installed via aqua, but in a reusable
workflow `actions/checkout` checks out the CALLER repo, so the aqua
config that ships with the workflow is not on disk at runtime. Composite
actions instead expose `${{ github.action_path }}` — the directory the
action was downloaded into — so we can ship `aqua.yaml` next to
`action.yml` and reference it without any checkout gymnastics.

## Who can call it

Any repository under either of these owners:

- **`Shion1305`** (personal user)
- **`Shion1305Dev`** (organization)

Repos outside those owners will fail at the Vault login step. This is
enforced server-side in Vault — it cannot be bypassed by the calling
workflow.

## Minimum caller (copy-paste this)

```yaml
name: build & push image

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  build-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write   # REQUIRED — Vault JWT login + cosign keyless sign
    steps:
      - uses: actions/checkout@v6
      - uses: Shion1305/k8s-GitOps/.github/actions/harbor-build-push@main
        with:
          image: harbor.shion1305.com/shion1305/<your-app>
          push: "true"
```

That's it. The action handles everything else.

> **`permissions: id-token: write` is mandatory** on the calling job.
> Composite actions inherit the calling job's permissions and cannot
> define their own, so the caller has to grant this. Without it, the
> Vault login step fails with a 403 on the
> `/_apis/distributedtask/.../oidctoken` endpoint.

> **`actions/checkout` is required** before the `uses:` line. Composite
> actions run inline in the caller's job and have no implicit access to
> the caller's source tree. The build-context input is resolved against
> `$GITHUB_WORKSPACE`, so the caller must populate it first.

## Inputs

| Input        | Default                 | Description |
|--------------|-------------------------|-------------|
| `image`      | **required**            | Full image reference WITHOUT a tag, e.g. `harbor.shion1305.com/shion1305/myapp`. The robot account is scoped to the `shion1305` Harbor project, so the image MUST start with `harbor.shion1305.com/shion1305/`. Pushes elsewhere will be rejected at Harbor authz. |
| `context`    | `.`                     | Docker build context path (relative to repo root). |
| `dockerfile` | `Dockerfile`            | Dockerfile path relative to `context`. |
| `platforms`  | `linux/amd64,linux/arm64` | Comma-separated `buildx` target platforms. |
| `push`       | `"true"`                 | Whether to publish the built image. Set to `"false"` for validation-only builds; no Harbor credentials are fetched in that case. For a workflow that handles PRs and pushes, use `${{ github.event_name != 'pull_request' }}`. |
| `sign`       | `"true"`                | Whether to keyless-sign with cosign (Fulcio + Rekor). Defaulted ON because mixing signed and unsigned images is a supply-chain footgun. Pass the string `"false"` to disable. |
| `tag`        | `${{ github.sha }}`     | Primary tag pushed. Defaults to the calling repo's commit SHA so every build is uniquely addressable. |
| `extra-tags` | `""`                    | Comma-separated additional tags applied to the same digest (e.g. `latest,v1.2.3`). Empty by default — opt in explicitly if you want a moving `latest`. |

All inputs are strings. Composite actions don't have typed inputs, so
booleans are conveyed as the literal strings `"true"` / `"false"`.

## Outputs

| Output   | Description |
|----------|-------------|
| `digest` | The pushed manifest digest (e.g. `sha256:abc123...`). Use this in downstream deploy steps — tags can move, digests cannot. |
| `ref`    | Full pinned image reference: `<image>@<digest>`. Convenience output so callers don't have to re-concatenate. |

### Chaining to a deploy step

```yaml
jobs:
  build-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    outputs:
      ref: ${{ steps.harbor.outputs.ref }}
    steps:
      - uses: actions/checkout@v6
      - id: harbor
        uses: Shion1305/k8s-GitOps/.github/actions/harbor-build-push@main
        with:
          image: harbor.shion1305.com/shion1305/myapp
          push: "true"

  deploy:
    needs: build-push
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "Deploying ${{ needs.build-push.outputs.ref }}"
          # e.g. update a Helm values file with the digest, push, ArgoCD syncs.
```

> Step outputs are not exposed to other jobs by default — promote them
> via the job-level `outputs:` block as shown.

## How it works under the hood

```
┌─────────────────┐
│ GitHub Actions  │
│ runner          │
└────────┬────────┘
         │ 1. Mint OIDC JWT (audience = https://github.com/<owner>)
         ▼
┌─────────────────────────────────┐
│ token.actions.githubusercontent │
└────────┬────────────────────────┘
         │ 2. JWT
         ▼
┌─────────────────────────────────┐     ┌────────────────────┐
│ vault.shion1305.com (public)    │────▶│ Vault role:        │
│ POST /v1/auth/jwt/login         │     │ harbor-robot-pusher│
│   {role, jwt}                   │     │ - bound_audiences  │
└────────┬────────────────────────┘     │ - bound_claims:    │
         │ 3. Vault token (TTL 10m)     │   repository_owner │
         ▼                              │   job_workflow_ref │
┌─────────────────────────────────┐     └────────────────────┘
│ vault.shion1305.com (public)    │     ┌────────────────────┐
│ GET /v1/harbor/data/robot-pusher│────▶│ KV v2:             │
└────────┬────────────────────────┘     │ harbor/robot-pusher│
         │ 4. {username, password}      │ {username,password}│
         ▼                              └────────────────────┘
┌─────────────────────────────────┐
│ runner: write ~/.docker/config  │
│ runner: crane push --index      │────▶ harbor.shion1305.com/shion1305/<app>
│ runner: cosign sign (keyless)   │
└─────────────────────────────────┘
```

What makes this safe:

- The Vault role's `bound_claims` includes `job_workflow_ref` matching
  callers that invoke this action. A repo created under `Shion1305Dev`
  cannot obtain Harbor push creds unless it actually `uses:` this action.
- The Vault token TTL is 10 minutes — single-use, no renewal. Even if a
  workflow log were exfiltrated, the credential is dead by the time anyone
  reads it.
- The Harbor robot password itself never leaves the runner's job context.
  `~/.docker/config.json` lives on the ephemeral GitHub-hosted VM that is
  destroyed at job end.

## One-time prerequisites you DON'T need to do

You don't need to:

- Create any GitHub repo Secrets (no `HARBOR_ROBOT_USER`, no `HARBOR_ROBOT_TOKEN`).
- Touch Harbor.
- Touch Vault.
- Configure a service account or workload identity.

The Vault role and the Harbor robot account are already provisioned. Just
add the caller workflow.

## Troubleshooting

### `Error: Aud claim does not match expected values`

GitHub minted the OIDC token with a default audience of
`https://github.com/<your-repo-owner>`. The Vault role allows
`https://github.com/Shion1305` and `https://github.com/Shion1305Dev`. If
your repo owner is anything else, the workflow cannot use this pipeline.
Move the repo to one of the allowed owners or open a PR against
`vault/scripts/setup-eso-policies.sh` to add yours.

### `Error: bound claim 'repository_owner' does not match`

Same root cause as above. Repo owner outside the allowlist.

### `Error: bound claim 'job_workflow_ref' does not match`

You are calling a fork of the action, not
`Shion1305/k8s-GitOps/.github/actions/harbor-build-push`. Either:

- Switch your `uses:` line to point at `Shion1305/k8s-GitOps/...`, or
- Open a PR to add your fork's `job_workflow_ref` to the Vault role's
  `bound_claims`.

### `crane: command not found` during the push step

The aqua install step did not produce a working `crane` shim. The action
relies on `aqua_opts: -l -a` so that aqua-installer's `installAll` path
runs and consumes `AQUA_GLOBAL_CONFIG`. If you forked this action and
removed `-a`, restore it: lazy mode (`-l` alone) ignores the config file.

### `Error: Unable to retrieve result for "harbor/data/robot-pusher" because it was not found`

The vault-action received a 404. Possible causes:

1. The Vault HTTPRoute change has not propagated yet — try again in a few
   minutes.
2. The KV v2 path `harbor/robot-pusher` is empty or has been deleted. Open
   an issue against this repo.

### `Error: Vault returned empty Harbor robot credentials.`

The KV path exists but is missing the `username` or `password` field. Open
an issue against this repo.

### `denied: requested access to the resource is denied` (from crane)

`HARBOR_ROBOT_USER` and `HARBOR_ROBOT_TOKEN` made it to the runner but
Harbor rejected the push. Likely causes:

- The image path doesn't start with `harbor.shion1305.com/shion1305/`. The
  robot account only has push rights on the `shion1305` project.
- The robot account expired (Harbor robots default to 365d). Open an issue.

### `tlog upload failed: ... cosign sign failed`

Cosign keyless signing requires `id-token: write` permission on the calling
job AND outbound network access to Fulcio + Rekor. Both should be the case
on GitHub-hosted runners by default. If you set `sign: "false"` you can
skip signing entirely, but please don't — unsigned production images
defeat the supply-chain story.

## Versioning

Today, `@main` is the only stable ref. Breaking changes will be announced
in the PR description and a tag will be cut if/when consumers ask for one.
For now, pinning to `@main` is acceptable: every change to the action is
reviewed and the demo workflow re-runs end-to-end on each PR.

## Reference

- Action source: [`action.yml`](./action.yml)
- Aqua tool list: [`aqua.yaml`](./aqua.yaml)
- Demo caller: [`../../workflows/demo-push-to-harbor.yaml`](../../workflows/demo-push-to-harbor.yaml)
- Vault server config: [`../../../vault/scripts/setup-eso-policies.sh`](../../../vault/scripts/setup-eso-policies.sh) (search for `harbor-robot-pusher`)
- Vault external HTTPRoute: [`../../../vault/httproute-external.yaml`](../../../vault/httproute-external.yaml)
- Harbor architecture: [`../../../harbor/README.md`](../../../harbor/README.md)
