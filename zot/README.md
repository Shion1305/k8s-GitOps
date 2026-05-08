# zot — OCI Registry

Project-zot v2 deployed cluster-wide as the canonical container image registry for `registry.shion1305.com`.

## Hostnames and routing

Two hostnames front the same `zot` Service. Each has the same three HTTPRoutes:

| Hostname | Gateway | Catalog-probe HTTPRoute | Registry HTTPRoute | UI HTTPRoute |
| --- | --- | --- | --- | --- |
| `registry.shion1305.com` | `external` (public) | `zot-catalog-probe-external` | `zot-registry-external` | `zot-ui-external` |
| `registry.i.shion1305.com` | `internal` (WG-only) | `zot-catalog-probe-internal` | `zot-registry-internal` | `zot-ui-internal` |

- `zot-catalog-probe-*` — exact `/v2/` and `/v2/_catalog`. The SPA pings these at `/login` boot. Targeted by the OIDC `SecurityPolicy` so the browser request arrives at zot with the kc_at injected.
- `zot-registry-*` — the broad `/v2/` PathPrefix that handles every push/pull. **Not** behind the OIDC policy — containerd negotiates its own bearer challenge with zot, and a 302 to Keycloak would break every kubelet pull.
- `zot-ui-*` — `/` and `/v2/_zot/*` (SPA bundle, `/zot/auth/*`, zot's extension XHRs). Fully behind the OIDC `SecurityPolicy`.

Gateway API GEP-718 most-specific-path-wins keeps `/v2/_zot/...` on `zot-ui-*` and routes `/v2/` and `/v2/_catalog` exact matches to `zot-catalog-probe-*` over the bare `/v2/` PathPrefix on `zot-registry-*`. Per-rule `sectionName` targeting would be cleaner but requires `HTTPRouteRule.name` (Gateway API v1.2+) which ArgoCD v3.4's embedded OpenAPI schema rejects at diff time, so the rules are split into separate HTTPRoutes instead.

## Auth callers

Three distinct caller types reach zot. Browser UI auth is mediated by Envoy Gateway; machine callers go straight to zot's bearer-OIDC middleware.

```
                    ┌────────────────────────────────────────────────────────────┐
                    │                        envoy-gateway                       │
                    │                                                            │
  GHA crane push ───┼─→ /v2/* ─────────────────────────────────────────────────┐ │
  (Bearer JWT)      │                                                          │ │
                    │                                                          ▼ │
  kubelet pull ─────┼─→ /v2/* ─→ [Lua: Basic(oidc:JWT)→Bearer JWT] ──────────→ zot
  (Basic JWT)       │                                                          ▲ │
                    │                                                          │ │
  Browser UI ───────┼─→ /, /v2/_zot/* ─→ [SecurityPolicy.oidc → Keycloak] ─────┤ │
  (cookie / OIDC)   │      and /v2/, /v2/_catalog (catalog-probe rule)         │ │
                    │      [Lua: rewrite /v2/_zot/ext/mgmt response]           │ │
                    └────────────────────────────────────────────────────────────┘
```

### 1. GitHub Actions push (`Authorization: Bearer <gh-oidc>`)

`crane` reads `~/.docker/config.json` and sends `registrytoken` pre-emptively as Bearer. Validated by `http.auth.bearer.oidc[token.actions.githubusercontent.com]`. CEL claim mapping derives `username = claims.repository` and assigns the right pusher group from `repository_owner`. See `.github/workflows/demo-push-to-zot.yaml`.

### 2. Kubelet/containerd pull (`Authorization: Basic base64("oidc:<jwt>")`)

containerd reads the dockerconfigjson Secret materialised by ESO (see `../zot-pull/`) and goes through the standard Docker Registry v2 challenge/retry handshake. zot's bearer-OIDC middleware short-circuits at `pkg/api/authn.go:65-67`, so two things break end-to-end without help:

1. zot returns 401 to the unauthenticated probe with **no `WWW-Authenticate` header**. containerd interprets this as "no scheme advertised" and never retries with credentials.
2. Even if containerd retries, the dockerconfig `auth` field is sent verbatim as `Authorization: Basic ...`, which zot's bearer middleware refuses to parse.

The `zot-basic-to-bearer` filter in `envoy-extension-policy.yaml` ships a Lua filter on the two `zot-registry-*` HTTPRoutes that fixes both halves:

- `envoy_on_request` flags requests from containerd-class User-Agents (`containerd/*`, `docker/*`, `Go-http-client/*` — covers kubelet, the Docker daemon, and `crane`) by stashing `zot.basic_to_bearer/wants_basic_challenge=true` in dynamic metadata. It also decodes any incoming `Basic base64("oidc:<jwt>")` and rewrites it to `Bearer <jwt>` before it reaches zot.
- `envoy_on_response` reads the metadata flag. On a 401 from a flagged request that lacks `WWW-Authenticate`, it injects `Basic realm="zot"`. containerd then retries with the credential from the imagePullSecret. The retry's JWT is validated by `http.auth.bearer.oidc[keycloak]` (audience `zot-registry`, hardcoded `groups` mapper on the Keycloak `cluster-puller` client).

Browsers are deliberately excluded from the response-side injection: the SPA hits `/v2/` and `/v2/_catalog` during boot. Without the User-Agent gate, the browser would pop up its native Basic-auth dialog before the user could click "Sign in with OIDC".

GHA push traffic from `crane` matches the `Go-http-client` UA so the metadata flag is set, but `crane` sends `Bearer` pre-emptively (`registrytoken`) and never receives a 401, so the response-side injection is a no-op for push.

### 3. Browser UI (Envoy SecurityPolicy.oidc, cookie session)

Browsers hit `/`, `/v2/_zot/*`, and the SPA's two boot probes (`/v2/`, `/v2/_catalog`). All four are covered by `securitypolicy.yaml`'s OIDC policy (whole-route attachment for `zot-ui-*`, `sectionName`-scoped attachment for `zot-registry-*` `catalog-probe`).

On first load, Envoy runs the Authorization Code flow against the Keycloak `zot` realm using the `zot-ui` confidential client. After the callback at `/oauth2/callback`, Envoy sets an encrypted session cookie (`zot_at` / `zot_it`) and forwards the Keycloak access_token upstream as `Authorization: Bearer <kc_at>`. zot's `bearer.oidc[keycloak]` validates the same token (audience `zot-registry`) and authorizes by the `groups` claim from the `zot-ui` client's group-membership mapper.

#### Why zot's native `http.auth.openid` is not used

zot v2.1.16's `AuthHandler` short-circuits to its bearer middleware whenever `bearer.oidc[]` is configured (`pkg/api/authn.go:65-67`), so the openid `LoginPath` handler never gets `RelyingParties` initialised and 400s on a nil-map miss. This is upstream issue [project-zot/zot#4033](https://github.com/project-zot/zot/issues/4033) — maintainer-confirmed intended behaviour ("bearer authentication excludes all other authentication options"). Routing UI auth through Envoy keeps machine callers (GHA, kubelet) on `bearer.oidc[]` without running into the conflict.

#### SPA login state with upstream auth

zui (`commit-9333420`, embedded in zot v2.1.16) decides "logged in" via `isAuthenticated()` at `src/utilities/authUtilities.js:31-37`:

1. Cookie `user` set → logged in. zot only sets this from its own htpasswd/LDAP/OIDC-callback paths, none of which run here.
2. `localStorage.authConfig === '{}'` → logged in (the "no auth configured" branch). Triggered when the SPA's `/v2/_zot/ext/mgmt` probe at `SignIn.jsx:171` sees an empty `http.auth` block.

Because zot still has `bearer.oidc[]` configured for machine callers, its mgmt response advertises `{auth:{bearer:{}}}`. The stock SPA would render a blank login card it can't act on. The `zot-ui-mgmt-rewrite` filter in `envoy-extension-policy.yaml` rewrites the mgmt response body on the UI routes to drop `http.auth`, making the SPA take its auto-login branch and navigate to `/home`. From there every XHR (`/v2/_zot/ext/search`, etc.) rides the cookie session and the Envoy-injected Bearer; zot validates and serves.

#### XHR vs navigation handling

`SecurityPolicy.oidc` defaults to 302-redirecting any unauthenticated request to Keycloak. Cross-origin 302 cannot be followed by `fetch()` (opaque response), so the `denyRedirect.headers` matchers force 401 for AJAX requests (`Sec-Fetch-Mode: cors`, `Sec-Fetch-Dest: empty`, `X-Requested-With: XMLHttpRequest`). The Axios interceptor at `src/api.js:21-26` then redirects to `/login`, which is a top-level navigation and CAN follow the 302 to Keycloak. Same flow for cookie expiry mid-session.

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
- Keycloak `zot` realm → `groups` claim, populated by per-client mappers (group-membership mapper on `zot-ui` for browser users; hardcoded mapper on `cluster-puller` for kubelet pulls).

## ExternalSecrets

The OIDC client credentials used by Envoy's `SecurityPolicy.oidc` are sourced from Vault and projected into a Kubernetes Secret. zot itself no longer needs any on-disk secret material.

| ExternalSecret | Vault path | Secret keys | Purpose |
| --- | --- | --- | --- |
| `zot-ui-oidc-credentials` | `zot/openid-credentials` (field `keycloak-credentials.json`, JSON blob) | `client-id`, `client-secret` | Referenced by `securitypolicy.yaml` for the OIDC code flow |

The Vault blob is a single JSON field of shape `{"clientid":"zot-ui","clientsecret":"..."}`; the ESO template parses it with `fromJson` and emits the two keys Envoy expects. The same Vault path was used by the previous zot-native flow, so no Vault re-key is needed for this migration.

The ServiceAccount/SecretStore plumbing is unchanged from the previous architecture — `eso-zot` Kubernetes auth role bound to the namespace's ServiceAccount, `secret-store.yaml` declares the SecretStore, `reference-grant.yaml` lets the in-namespace HTTPRoutes attach to the cross-namespace Gateways.

## Cluster-wide pull credential

The pull-side credential pipeline lives outside this directory:

- `../zot-pull-source/` — namespace holding the canonical `zot-pull` dockerconfigjson Secret, populated by ESO from a Keycloak access_token (ClusterGenerator `keycloak-cluster-puller-token`).
- `../zot-pull/` — `ClusterExternalSecret` definitions that materialise the Secret in `zot-pull-source` (one for the puller credentials, one for the dockerconfigjson token).
- `../kyverno-policies/zot-pull-injection.yaml` — Kyverno mutate (injects `imagePullSecrets`) + generate.clone (fans the Secret out to consumer namespaces) on Pod admission for any image referencing `registry.i.shion1305.com/*`.

## Image pinning

zot's upstream Helm chart hard-pins to architecture-specific images (`zot-linux-amd64` / `zot-linux-arm64`) instead of a multi-arch manifest list. `values.yaml` pins `zot-linux-amd64` and constrains scheduling with `nodeSelector: kubernetes.io/arch: amd64`. Drop both if upstream switches to a manifest list.
