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

Each GitHub owner is bound to its own Vault role, which yields a robot
account scoped to exactly one Harbor project:

| GitHub owner | `vault-role` | `vault-secret-path` | Harbor project |
|---|---|---|---|
| `Shion1305` (user), `Shion1305Dev` (org) | `harbor-robot-pusher` (default) | `harbor/data/robot-pusher` (default) | `shion1305` |
| `aal-hack` (org) | `harbor-robot-pusher-aal-hack` | `harbor/data/robot-pusher-aal-hack` | `aal-hack` |

Repos outside those owners fail at the Vault login step, and passing
another owner's role name does not help: Vault checks `repository_owner`
in the runner's OIDC token server-side, so the binding cannot be bypassed
by the calling workflow.

## Minimum caller (copy-paste this)

For a repo under `Shion1305` / `Shion1305Dev`:

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

For a repo under `aal-hack`, point the three owner-specific inputs at that
owner's role, KV path and Harbor project — everything else is identical:

```yaml
      - uses: Shion1305/k8s-GitOps/.github/actions/harbor-build-push@main
        with:
          image: harbor.shion1305.com/aal-hack/<your-app>
          vault-role: harbor-robot-pusher-aal-hack
          vault-secret-path: harbor/data/robot-pusher-aal-hack
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
| `image`      | **required**            | Full image reference WITHOUT a tag, e.g. `harbor.shion1305.com/shion1305/myapp`. The robot account is scoped to one Harbor project, so the image MUST start with `harbor.shion1305.com/<that-project>/`. Pushes elsewhere will be rejected at Harbor authz. |
| `vault-role` | `harbor-robot-pusher`   | Vault JWT role exchanged for the robot credentials. Must be the role bound to your repo's owner — see [Who can call it](#who-can-call-it). |
| `vault-secret-path` | `harbor/data/robot-pusher` | KV v2 data path the role grants read access to. Must match `vault-role`; a mismatched pair 403s at the KV read. |
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
│ POST /v1/auth/jwt/login         │     │ <vault-role>       │
│   {role, jwt}                   │     │ - bound_audiences  │
└────────┬────────────────────────┘     │ - bound_claims:    │
         │ 3. Vault token (TTL 10m)     │   repository_owner │
         ▼                              └────────────────────┘
┌─────────────────────────────────┐     ┌────────────────────┐
│ vault.shion1305.com (public)    │     │ KV v2:             │
│ GET /v1/<vault-secret-path>     │────▶│ the owner's robot  │
└────────┬────────────────────────┘     │ {username,password}│
         │ 4. {username, password}      └────────────────────┘
         ▼
┌─────────────────────────────────┐
│ runner: write ~/.docker/config  │
│ runner: crane push --index      │────▶ harbor.shion1305.com/<project>/<app>
│ runner: cosign sign (keyless)   │
└─────────────────────────────────┘
```

What makes this safe:

- Each owner's Vault role reads exactly one KV path, and the robot behind
  it can push to exactly one Harbor project. A repo under `aal-hack`
  cannot reach the `shion1305` project and vice versa.
- The Vault token TTL is 10 minutes — single-use, no renewal. Even if a
  workflow log were exfiltrated, the credential is dead by the time anyone
  reads it.
- The Harbor robot password itself never leaves the runner's job context.
  `~/.docker/config.json` lives on the ephemeral runner that is destroyed
  at job end.

What this does NOT protect against: within an allowed owner, any repo with
`id-token: write` on a job can mint that owner's robot credentials without
going through this action. `job_workflow_ref` describes the caller's own
workflow file, not the composite actions it loads, so there is no
server-side claim that could prove "the caller used this action". Owner
separation — one role, one robot, one project per owner — is the boundary
that actually holds.

## One-time prerequisites you DON'T need to do

If your repo's owner is already in the table under
[Who can call it](#who-can-call-it), you don't need to:

- Create any GitHub repo Secrets (no `HARBOR_ROBOT_USER`, no `HARBOR_ROBOT_TOKEN`).
- Touch Harbor.
- Touch Vault.
- Configure a service account or workload identity.

That owner's Vault role and Harbor robot account are already provisioned.
Just add the caller workflow.

Onboarding a brand-new owner is a cluster-operator task — Harbor project,
robot account, Vault path, Vault role and gateway allowlist entry. See
[Onboard a new pushing GitHub owner](../../../harbor/README.md#onboard-a-new-pushing-github-owner).

## Troubleshooting

### `Error: Aud claim does not match expected values`

GitHub minted the OIDC token with a default audience of
`https://github.com/<your-repo-owner>`, and the `vault-role` you passed is
not bound to that owner. Either you left `vault-role` at its default from
an `aal-hack` repo (or set the `aal-hack` role from a `Shion1305*` repo) —
fix the input per [Who can call it](#who-can-call-it) — or your owner has
no role at all, in which case open a PR against
`vault/scripts/setup-eso-policies.sh` to add one.

### `Error: bound claim 'repository_owner' does not match`

Same root cause as above. Repo owner outside the role's allowlist.

### `crane: command not found` during the push step

The aqua install step did not produce a working `crane` shim. The action
relies on `aqua_opts: -l -a` so that aqua-installer's `installAll` path
runs and consumes `AQUA_GLOBAL_CONFIG`. If you forked this action and
removed `-a`, restore it: lazy mode (`-l` alone) ignores the config file.

### `Error: Unable to retrieve result for "<vault-secret-path>" ... not found`

The vault-action received a 404 (or a 403 rendered as one). Possible
causes:

1. `vault-secret-path` does not match `vault-role` — the role's policy
   only grants read on its own path. See
   [Who can call it](#who-can-call-it).
2. The path is not in the public Vault allowlist. `vault.shion1305.com`
   proxies only explicitly listed paths
   (`vault/httproute-external.yaml`), so a path missing there is rejected
   at the gateway even when the Vault policy is correct.
3. The Vault HTTPRoute change has not propagated yet — try again in a few
   minutes.
4. The KV v2 path is empty or has been deleted. Open an issue against this
   repo.

### `Error: Vault returned empty Harbor robot credentials.`

The KV path exists but is missing the `username` or `password` field. Open
an issue against this repo.

### `denied: requested access to the resource is denied` (from crane)

`HARBOR_ROBOT_USER` and `HARBOR_ROBOT_TOKEN` made it to the runner but
Harbor rejected the push. Likely causes:

- The image path's project segment doesn't match the project the robot is
  scoped to (see [Who can call it](#who-can-call-it)) — e.g. an `aal-hack`
  repo pushing to `harbor.shion1305.com/shion1305/…`.
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
