# zot — OCI Registry

Project-zot v2 deployed cluster-wide as the canonical container image registry for `registry.shion1305.com`.

## Hostnames and routing

Two hostnames front the same `zot` Service. The split-by-path pattern applies to both:

| Hostname | Gateway | HTTPRoute (`/v2/`) | HTTPRoute (`/`, `/v2/_zot/`) |
| --- | --- | --- | --- |
| `registry.shion1305.com` | `external` (public) | `zot-registry-external` | `zot-ui-external` |
| `registry.i.shion1305.com` | `internal` (WireGuard-only) | `zot-registry-internal` | `zot-ui-internal` |

The `/v2/` routes carry Docker Registry v2 protocol traffic (push/pull). The other routes serve the SPA, OIDC login flow, and zot's own extension XHRs (`/v2/_zot/...`). Gateway API most-specific-path-wins (GEP-718) keeps `/v2/_zot/...` on the UI route even though `/v2/` matches.

## Auth callers

Three distinct caller types reach zot. zot itself does no Envoy-level OIDC mediation — it speaks to each upstream issuer directly.

```
                    ┌─────────────────────────────────────────────────────┐
                    │                 envoy-gateway                       │
                    │                                                     │
  GHA crane push ───┼─→ /v2/* ──────────────────────────────────────────┐ │
  (Bearer JWT)      │                                                   │ │
                    │                                                   ▼ │
  kubelet pull ─────┼─→ /v2/* ─→ [Lua: Basic(oidc:JWT)→Bearer JWT] ───→ zot
  (Basic JWT)       │                                                   ▲ │
                    │                                                   │ │
  Browser UI ───────┼─→ /, /v2/_zot/* ──────────────────────────────────┘ │
  (cookie / OIDC)   │                                                     │
                    └─────────────────────────────────────────────────────┘
```

### 1. GitHub Actions push (`Authorization: Bearer <gh-oidc>`)

`crane` reads `~/.docker/config.json` and sends `registrytoken` pre-emptively as Bearer. Validated by `http.auth.bearer.oidc[token.actions.githubusercontent.com]`. CEL claim mapping derives `username = claims.repository` and assigns the right pusher group from `repository_owner`. See `.github/workflows/demo-push-to-zot.yaml`.

### 2. Kubelet/containerd pull (`Authorization: Basic base64("oidc:<jwt>")`)

containerd reads the dockerconfigjson Secret materialised by ESO (see `../zot-pull/`) and goes through the standard Docker Registry v2 challenge/retry handshake. zot's bearer-OIDC middleware short-circuits at `pkg/api/authn.go:65-67`, so two things break end-to-end without help:

1. zot returns 401 to the unauthenticated probe with **no `WWW-Authenticate` header**. containerd interprets this as "no scheme advertised" and never retries with credentials.
2. Even if containerd retries, the dockerconfig `auth` field is sent verbatim as `Authorization: Basic ...`, which zot's bearer middleware refuses to parse.

`envoy-extension-policy.yaml` ships a Lua filter on the two `/v2/` HTTPRoutes that fixes both halves:

- `envoy_on_request` flags requests from containerd-class User-Agents (`containerd/*`, `docker/*`, `Go-http-client/*` — covers kubelet, the Docker daemon, and `crane`) by stashing `zot.basic_to_bearer/wants_basic_challenge=true` in dynamic metadata. It also decodes any incoming `Basic base64("oidc:<jwt>")` and rewrites it to `Bearer <jwt>` before it reaches zot.
- `envoy_on_response` reads the metadata flag. On a 401 from a flagged request that lacks `WWW-Authenticate`, it injects `Basic realm="zot"`. containerd then retries with the credential from the imagePullSecret. The retry's JWT is validated by `http.auth.bearer.oidc[keycloak]` (audience `zot-registry`, hardcoded `groups` mapper on the Keycloak `cluster-puller` client).

Browsers are deliberately excluded from the response-side injection: the SPA hits `/v2/` and `/v2/_catalog` during boot and 401s on those endpoints. Without the User-Agent gate, the browser would pop up its native Basic-auth dialog before the user could click "Sign in with OIDC".

GHA push traffic from `crane` matches the `Go-http-client` UA so the metadata flag is set, but `crane` sends `Bearer` pre-emptively (`registrytoken`) and never receives a 401, so the response-side injection is a no-op for push.

### 3. Browser UI (cookie session)

Browsers hit `/` and `/v2/_zot/*`. zot's native `http.auth.openid` provider runs the Authorization Code Flow against the same Keycloak realm, then mints a session cookie. SPA routes `/zot/auth/login/oidc` → `/zot/auth/callback/oidc` → `/`. zot's validator only accepts provider keys `google`/`gitlab`/`oidc` for OpenID, so the provider key is `oidc` (not `keycloak`).

## Access control

`http.accessControl` is group-based:

| Group | Repo glob | Actions |
| --- | --- | --- |
| `pusher-shion1305` | `shion1305/**` | read, create, update |
| `pusher-shion1305dev` | `shion1305dev/**` | read, create, update |
| `zot-admin` | `**` (admin policy) | read, create, update, delete |
| _(none)_ | `**` | read (default policy) |

Group claims come from each issuer:

- GHA OIDC → CEL claim mapping derives the group from `repository_owner` (`Shion1305` → `pusher-shion1305`, `Shion1305Dev` → `pusher-shion1305dev`).
- Keycloak `zot` realm → `groups` claim, populated by per-client mappers.

## ExternalSecrets

Two on-disk artefacts are required for the OpenID UI flow and are mounted as files into the zot Pod via the chart's `externalSecrets[]` hook:

| ExternalSecret | Vault path | Mount path | Purpose |
| --- | --- | --- | --- |
| `zot-openid-credentials` | `zot/openid-credentials` | `/secrets/openid` | `keycloak-credentials.json` (zot-ui client_id + client_secret) |
| `zot-session-keys` | `zot/session-keys` | `/secrets/session` | `sessionKeys.json` (gorilla session HMAC + AES-CTR keys) |

Both are wired through the namespace's `SecretStore` (`secret-store.yaml`) backed by Kubernetes auth role `eso-zot`.

## Cluster-wide pull credential

The pull-side credential pipeline lives outside this directory:

- `../zot-pull-source/` — namespace holding the canonical `zot-pull` dockerconfigjson Secret, populated by ESO from a Keycloak access_token (ClusterGenerator `keycloak-cluster-puller-token`).
- `../zot-pull/` — `ClusterExternalSecret` definitions that materialise the Secret in `zot-pull-source` (one for the puller credentials, one for the dockerconfigjson token).
- `../kyverno-policies/zot-pull-injection.yaml` — Kyverno mutate (injects `imagePullSecrets`) + generate.clone (fans the Secret out to consumer namespaces) on Pod admission for any image referencing `registry.i.shion1305.com/*`.

## Image pinning

zot's upstream Helm chart hard-pins to architecture-specific images (`zot-linux-amd64` / `zot-linux-arm64`) instead of a multi-arch manifest list. `values.yaml` pins `zot-linux-amd64` and constrains scheduling with `nodeSelector: kubernetes.io/arch: amd64`. Drop both if upstream switches to a manifest list.
