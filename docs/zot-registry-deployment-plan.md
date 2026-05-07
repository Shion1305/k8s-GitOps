# zot Registry Deployment Plan (Bearer-Only + Envoy Gateway OIDC)

> **Status**: 2026-05-08 — Replaces the previous Keycloak-token-exchange-based plan.
> The token-exchange approach was retired in PR #280 because Keycloak 26+ marks
> token-exchange v1 deprecated and the v2 path requires Fine-Grained Admin
> Permissions (FGAP) configuration that cannot be expressed declaratively in
> `KeycloakRealmImport`. This document captures the **new architecture** and
> the discrete PRs needed to ship it.

---

## 1. Goal

- `Shion1305` and `Shion1305Dev` GitHub Actions workflows can `docker push`
  to a self-hosted OCI registry **without storing static registry credentials
  as GitHub secrets** (no long-lived password / robot token).
- Humans can log in to the zot Web UI with their Keycloak passkey.
- Workloads inside the Kubernetes cluster can `imagePullSecrets`-pull from
  the same registry, with auto-rotated credentials.
- Avoid all deprecated Keycloak features (token-exchange v1, FGAP-based
  authorization for IdPs).

---

## 2. Final architecture

### 2.1 Components

```
                    ┌──────────────────────────────┐
                    │   GitHub Actions runner      │
                    │   (id-token: write)          │
                    └──────────────┬───────────────┘
                                   │ docker login + docker push
                                   │ Authorization: Bearer <gha-oidc-jwt>
                                   │ aud=registry.shion1305.com
                                   ▼
       ┌───────────────────────────────────────────────────┐
       │ Envoy Gateway (external)                          │
       │ ├─ HTTPRoute zot-registry-external (/v2/)         │  ← no SecurityPolicy
       │ │     └─→ zot Service                              │
       │ │                                                  │
       │ └─ HTTPRoute zot-ui-external (/, /v2/_zot/)        │  ← SecurityPolicy.oidc
       │       SecurityPolicy.oidc:                         │
       │         provider = keycloak.shion1305.com/realms/  │
       │                    zot                             │
       │         forwardAccessToken = true                  │
       │         passThroughAuthHeader = true               │
       │       └─→ zot Service                              │
       └───────────────────────────────────────────────────┘
                                   │
                                   ▼
       ┌───────────────────────────────────────────────────┐
       │ zot v2.1.16  (single Pod, Longhorn-backed PVC)    │
       │   http.auth.bearer.oidc[]:                        │
       │     ┌── issuer: token.actions.githubusercontent.com│
       │     │   audiences: [registry.shion1305.com]       │
       │     │   CEL: validate repository_owner is allow-  │
       │     │        listed; map groups by owner          │
       │     │                                              │
       │     └── issuer: keycloak.shion1305.com/realms/zot │
       │         audiences: [zot-registry]                 │
       │         claimMapping: groups passes through       │
       │   http.accessControl: ACL by group                │
       └───────────────────────────────────────────────────┘
                                   ▲
                                   │
                                   │ Authorization: Bearer <kc_at>
                                   │   (Envoy injects on UI route, OR
                                   │    kubelet sends from imagePullSecret)
                                   │
       ┌───────────────────────────┴───────────────────────┐
       │ Browsers, kubelet, internal `docker pull` clients │
       └───────────────────────────────────────────────────┘
```

### 2.2 Trust map

| Caller | Token issuer | Audience | Validated by | Authorization |
|---|---|---|---|---|
| GitHub Actions (push) | `token.actions.githubusercontent.com` | `registry.shion1305.com` | zot `bearer.oidc[0]` | CEL on `repository_owner`; groups via ternary on owner |
| Browser (UI login) | Keycloak realm `zot` | `zot-registry` | Envoy `SecurityPolicy.oidc` ↔ `forwardAccessToken: true` ↔ zot `bearer.oidc[1]` | `groups` claim (Keycloak group-membership mapper) |
| Kubelet (cluster pull) | Keycloak realm `zot` (service account) | `zot-registry` | zot `bearer.oidc[1]` | `groups` claim (hardcoded mapper) |
| WireGuard host (manual `docker pull`) | Keycloak realm `zot` (service account, same client as kubelet) | `zot-registry` | zot `bearer.oidc[1]` | `groups` claim |

**Anonymous `docker pull` is NOT supported.** zot v2.1.16 with `bearer.oidc[]`
short-circuits to 401 on any request without `Authorization: Bearer ...`,
even when `accessControl.repositories.**.defaultPolicy` permits read. This is
a hard constraint of the upstream code (`pkg/api/authn.go:58-69` — bearer
handler is exclusive). Verified empirically.

### 2.3 What was removed

- `oauth2-proxy` (was previously planned as the bearer-injecting bridge for
  the UI route). Replaced by Envoy Gateway's native `SecurityPolicy.oidc`,
  which provides identical capabilities (cookie-encrypted session, AT
  refresh from RT, `forwardAccessToken: true` to inject `Authorization`
  upstream). This deletes one Helm chart, one Vault secret, and one
  ServiceAccount from the architecture.
- `gha-exchanger` Keycloak client. GHA tokens are now validated directly by
  zot, not exchanged.
- `github-actions` Identity Provider in Keycloak. Same reason.
- `keycloak-credentials.json` and `session-keys.json` from zot's mounted
  secret volume. zot is bearer-only and reads no on-disk secret.

---

## 3. Realm structure (`zot` realm in Keycloak)

| Object | Purpose |
|---|---|
| Realm role / group `zot-admin` | Full read/create/update/delete on all repos |
| Realm role / group `pusher-shion1305` | Push to `shion1305/**` |
| Realm role / group `pusher-shion1305dev` | Push to `shion1305dev/**` |
| Identity Provider `user` (alias) | Brokered passkey login from realm `user` |
| Client `zot-registry` | Audience-only (the literal `aud` zot validates against). No flow enabled. Secret is irrelevant. |
| Client `zot-ui` (renamed from `oauth2-proxy`) | Confidential client used by Envoy Gateway's OIDC SecurityPolicy. Standard flow only. Has `groups` mapper + `zot-registry-audience` mapper. |
| Client `cluster-puller` | Confidential client, **service-account** flow (`grant_type=client_credentials`). Used by ESO ClusterGenerator to mint pull tokens. Has `zot-registry-audience` mapper + hardcoded `groups` claim. |

---

## 4. Repo layout after the change

```
zot/                                     # zot Helm + zot-namespace manifests
├── values.yaml                          # bearer.oidc[GHA, KC] + accessControl
├── kustomization.yaml                   # adds securitypolicy.yaml
├── secret-store.yaml                    # SecretStore (vault) — for zot-ui creds
├── external-secret.yaml                 # ExternalSecret zot-ui-oidc-credentials
├── reference-grant.yaml                 # unchanged
├── httproute-external.yaml              # 2 HTTPRoutes: zot-registry-external + zot-ui-external
├── httproute-internal.yaml              # 2 HTTPRoutes: zot-registry-internal + zot-ui-internal
├── securitypolicy.yaml                  # NEW: SecurityPolicy.oidc → zot-ui routes
└── README.md                            # NEW: deployment + manual steps

zot-pull/                                # NEW dir: cluster-wide pull automation
├── cluster-secret-store.yaml            # ClusterSecretStore (vault, role eso-cluster-puller)
├── credentials-external-secret.yaml     # mat. cluster-puller creds in external-secrets ns
├── cluster-generator.yaml               # ClusterGenerator (Webhook → Keycloak token endpoint)
├── cluster-external-secret.yaml         # ClusterExternalSecret → fan out dockerconfigjson
└── kustomization.yaml

apps/
├── zot-app.yaml                         # multi-source: zot Helm chart + zot/ dir
└── zot-pull-app.yaml                    # NEW: single-source app for zot-pull/

keycloak-operator/
├── zot-realm.yaml                       # adds cluster-puller client; renames oauth2-proxy → zot-ui
└── README.md                            # updated realm table

vault/scripts/
└── setup-eso-policies.sh                # adds eso-cluster-puller policy + role

.github/workflows/
└── demo-push-to-zot.yaml                # already updated: drops token-exchange, audience = registry.shion1305.com
```

---

## 5. Detailed file-by-file changes

### 5.1 `zot/values.yaml`

- Replace `http.auth.openid` with `http.auth.bearer.oidc[]` (two entries).
- Drop `http.auth.sessionKeysFile`.
- Drop `extraVolumes` / `extraVolumeMounts` (no on-disk secrets).
- Keep `accessControl` unchanged (groups → actions mapping).
- Add a comment block describing the two-issuer model.

### 5.2 `zot/external-secret.yaml`

- Rename `zot-oidc` → `zot-ui-oidc-credentials`.
- Drop `keycloak-credentials.json` template (zot doesn't read it anymore).
- Drop `session-keys.json` template (zot is bearer-only).
- New shape: type `Opaque`, keys `client-id` (literal "oauth2-proxy" until
  task #5.6 lands; then "zot-ui") and `client-secret` (templated from Vault
  `zot/keycloak-client.clientsecret`).
- Envoy Gateway's `SecurityPolicy.clientIDRef`/`clientSecret` consumes this.

### 5.3 `zot/httproute-external.yaml` and `zot/httproute-internal.yaml`

- Each file: split single `zot-external` / `zot-internal` HTTPRoute into TWO:
  - `zot-registry-{external,internal}`: matches `PathPrefix: /v2/`.
  - `zot-ui-{external,internal}`: matches `PathPrefix: /` AND `/v2/_zot/`.
- Backend on both: `Service zot:5000`.
- Path-precedence (most-specific-wins, GEP-718) routes `/v2/_zot/*` to the
  UI route, `/v2/*` (other paths) to the registry route.

### 5.4 `zot/securitypolicy.yaml` (new)

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata: { name: zot-ui-oidc, namespace: zot }
spec:
  targetRefs:
    - { group: gateway.networking.k8s.io, kind: HTTPRoute, name: zot-ui-external }
    - { group: gateway.networking.k8s.io, kind: HTTPRoute, name: zot-ui-internal }
  oidc:
    provider: { issuer: https://keycloak.shion1305.com/realms/zot }
    clientIDRef: { name: zot-ui-oidc-credentials }
    clientSecret: { name: zot-ui-oidc-credentials }
    # redirectURL omitted: Envoy auto-derives https://<:authority>/oauth2/callback
    logoutPath: /logout
    scopes: [email, profile, groups]
    cookieConfig: { sameSite: Lax }
    cookieNames: { accessToken: zot_at, idToken: zot_it }
    forwardAccessToken: true
    refreshToken: true
    passThroughAuthHeader: true
```

### 5.5 `zot/kustomization.yaml`

Add `securitypolicy.yaml` to `resources`.

### 5.6 `keycloak-operator/zot-realm.yaml` (separate PR)

> **This is the second PR**. It cannot land before the first PR ships, because
> realm changes require operator one-shot reimport (delete CR + delete realm
> in admin UI, ArgoCD recreates).

Changes:

- Rename client `oauth2-proxy` → `zot-ui` (also update header comments).
- Add new client `cluster-puller`:
  ```yaml
  - clientId: cluster-puller
    protocol: openid-connect
    publicClient: false
    clientAuthenticatorType: client-secret
    secret: PLACEHOLDER_REPLACE_AFTER_REALM_IMPORT
    standardFlowEnabled: false
    directAccessGrantsEnabled: false
    serviceAccountsEnabled: true
    attributes:
      access.token.lifespan: "3600"
    protocolMappers:
      - name: zot-registry-audience
        protocolMapper: oidc-audience-mapper
        protocol: openid-connect
        config:
          included.client.audience: "zot-registry"
          access.token.claim: "true"
          id.token.claim: "false"
      - name: groups-static
        protocolMapper: oidc-hardcoded-claim-mapper
        protocol: openid-connect
        config:
          claim.name: "groups"
          claim.value: '["pusher-shion1305", "pusher-shion1305dev"]'
          jsonType.label: "JSON"
          access.token.claim: "true"
  ```
  - Service account flow only; no human-facing flow.
  - Static `groups` claim with both pusher groups so the cluster can pull
    from both `shion1305/**` and `shion1305dev/**`. (Read is permitted by
    the per-repo `defaultPolicy: ["read"]`, so this static claim is mostly
    insurance against the default being changed.)
  - Audience mapper required because Keycloak service-account ATs default
    to `aud=account`.

Manual post-import steps:

1. Retrieve generated secrets for `zot-ui` and `cluster-puller` via admin UI.
2. `vault kv put zot/keycloak-client clientsecret=<zot-ui-secret>`
3. `vault kv put zot/cluster-puller client_id=cluster-puller client_secret=<cluster-puller-secret>`
4. Re-broker passkey users on first login (federated identity is dropped
   on realm recreate).

### 5.7 `zot-pull/` (new directory)

Files:

| File | Purpose |
|---|---|
| `cluster-secret-store.yaml` | ClusterSecretStore `vault-zot-cluster-puller` reading Vault path `zot/`, role `eso-cluster-puller`, SA `external-secrets/external-secrets`. |
| `credentials-external-secret.yaml` | ExternalSecret in `external-secrets` ns syncing `zot/cluster-puller.{client_id,client_secret}` → Secret `zot-cluster-puller-credentials`. |
| `cluster-generator.yaml` | ClusterGenerator `keycloak-cluster-puller-token` (kind: Webhook). POSTs `grant_type=client_credentials` to Keycloak token endpoint. References the credentials Secret above. Returns the full JSON `{access_token, expires_in, ...}`. |
| `cluster-external-secret.yaml` | ClusterExternalSecret with `namespaceSelector: { matchLabels: { zot-pull/enabled: "true" } }`, refreshInterval 15m. Uses `dataFrom.sourceRef.generatorRef`. Templates Secret of type `kubernetes.io/dockerconfigjson` with `auths: { registry.shion1305.com: { auth: b64("oidc:<at>") }, registry.i.shion1305.com: ... }`. |
| `kustomization.yaml` | Lists all four. |

Consuming a namespace:

```yaml
# in any namespace that needs to pull
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
  labels: { zot-pull/enabled: "true" }      # opt-in
---
# Then in the workload spec:
spec:
  imagePullSecrets:
    - { name: zot-pull }   # name is fixed by the ClusterExternalSecret target
```

### 5.8 `apps/zot-pull-app.yaml` (new)

Single-source ArgoCD app pointing at `zot-pull/`.

### 5.9 `vault/scripts/setup-eso-policies.sh`

Add at the bottom:

```bash
vault policy write eso-cluster-puller - <<EOF
path "zot/data/cluster-puller" { capabilities = ["read"] }
path "zot/metadata/cluster-puller" { capabilities = ["read", "list"] }
EOF

vault write auth/kubernetes/role/eso-cluster-puller \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-cluster-puller \
  ttl=1h
```

This script is run by hand by the operator (it's not GitOps-managed; it
sets up Vault-side policies), so the new lines just get added to the script
to document the canonical Vault state.

### 5.10 `.github/workflows/demo-push-to-zot.yaml`

Already updated:

- Drop the `Get token-exchange access_token` step.
- OIDC token request audience: `registry.shion1305.com` (not `zot-registry`).
- `docker login` username: literal `oidc` (zot ignores the username).
- Password: the GHA OIDC JWT directly.
- Drop `secrets.KEYCLOAK_GHA_EXCHANGER_SECRET` reference (and remove from
  the GitHub repo secrets store after merge).

### 5.11 New `zot/README.md`

Document:

- Architecture summary (link to this plan).
- How to grant a human user push rights (admin UI: realm `zot` → Users →
  add user → Groups → add to `pusher-shion1305` etc.).
- How to onboard a namespace to `zot-pull` (label + imagePullSecrets).
- How to recreate the realm (delete CR + delete realm in UI; ArgoCD
  reapplies; re-broker users; rewrite Vault secrets).
- Troubleshooting: 401 on push (audience mismatch?), 401 on pull (token
  rotation / expired?), 403 (groups missing).

### 5.12 Update `keycloak-operator/README.md`

Update the realm table to include `cluster-puller` and rename
`oauth2-proxy` → `zot-ui`.

---

## 6. Rollout sequence

1. **PR #278** — everything except realm rename + cluster-puller client:
   - `zot/values.yaml` switches to bearer-only
   - `zot/httproute-*.yaml` split
   - `zot/securitypolicy.yaml` new
   - `zot/external-secret.yaml` rewritten (still uses literal `oauth2-proxy`
     for `client-id`)
   - `zot/kustomization.yaml` updated
   - `zot/README.md` new
   - Updated docs
   - GHA demo workflow rewrite

   Result after merge:
   - Browser UI login still works because the existing `oauth2-proxy`
     Keycloak client + secret in Vault is reused; Envoy now drives the
     code flow instead of an oauth2-proxy pod (which never existed in
     production — the realm shipped first via PR #280, but no oauth2-proxy
     deployment was ever applied).
   - `docker push` from GHA works.
   - Cluster pull does NOT yet work; namespaces still need to use external
     pull paths if they pull from this registry.

2. **PR (this one) — realm rename + cluster-puller client + zot-pull/ + Vault role**.
   Stacked on PR #278's branch (`fix/demo-push-error-handling`) until #278
   merges, then rebased on `main`.
   - `keycloak-operator/zot-realm.yaml` renames `oauth2-proxy` → `zot-ui`,
     adds `cluster-puller`.
   - `zot/external-secret.yaml` updates `client-id: oauth2-proxy` →
     `client-id: zot-ui`.
   - `zot-pull/` directory (5 files: ClusterSecretStore, credentials
     ExternalSecret, ClusterGenerator, ClusterExternalSecret, kustomization)
     + `apps/zot-pull-app.yaml`.
   - `vault/scripts/setup-eso-policies.sh` adds eso-cluster-puller policy + role.
   - Manual steps required AFTER merge (realm recreate is destructive):
     a. `kubectl delete keycloakrealmimport zot -n keycloak`
     b. Admin UI: realm `zot` → Realm Settings → Action → Delete (drops
        federated-identity links — small impact, user count is small)
     c. ArgoCD recreates the import CR; operator reimports the realm.
     d. Admin UI: pull generated secrets for `zot-ui` and `cluster-puller`.
     e. `vault kv put zot/keycloak-client clientsecret=<zot-ui-secret>`
     f. `vault kv put zot/cluster-puller client_id=cluster-puller client_secret=<cluster-puller-secret>`
     g. Run `bash vault/scripts/setup-eso-policies.sh` to apply the new
        Vault policy + role.
     h. Re-broker passkey users on first login.
     i. Re-assign group memberships (`zot-admin`, `pusher-shion1305`,
        `pusher-shion1305dev`) to the appropriate users.

   Result after merge + manual steps:
   - All four trust paths in §2.2 are live.
   - Existing namespaces opt in by labeling and adding `imagePullSecrets`.

---

## 7. Verification plan

After PR #278 merges:

1. **Browser login**
   - Open `https://registry.shion1305.com/` in an incognito browser.
   - Expect 302 → `https://keycloak.shion1305.com/realms/zot/protocol/openid-connect/auth?...`
   - After passkey, expect 302 back to `/oauth2/callback`, then `/`.
   - SPA loads. Open dev tools → Network → confirm `/v2/_zot/ext/search`
     returns 200 (not 401).

2. **GHA push**
   - Trigger the `demo - build & push to registry.shion1305.com` workflow
     manually. Expect green.
   - `curl https://registry.shion1305.com/v2/_catalog -H "Authorization: Bearer <kc_at>"`
     should list `shion1305/demo`.

3. **Internal pull from WireGuard host (manual `docker login`)**
   - Get a token: `curl -s -X POST https://keycloak.shion1305.com/realms/zot/protocol/openid-connect/token -d "grant_type=client_credentials&client_id=cluster-puller&client_secret=$SECRET" | jq -r .access_token`
   - `docker login registry.i.shion1305.com -u oidc -p "$TOKEN"`
   - `docker pull registry.i.shion1305.com/shion1305/demo:latest`

After the second PR + realm recreate:

4. **Cluster pull**
   - Label a test namespace: `kubectl label ns test-pull zot-pull/enabled=true`
   - `kubectl get secret zot-pull -n test-pull` should appear within 5
     minutes (ClusterES refreshTime).
   - Apply a Pod referencing `imagePullSecrets: [{name: zot-pull}]` and an
     image at `registry.shion1305.com/shion1305/demo:latest`.
   - Pod reaches `Running`.

---

## 8. Failure-mode notes

- **Keycloak unreachable**: ESO leaves the last good Secret in place
  (`creationPolicy: Owner` does not delete on error). Pulls keep working
  until the cached AT expires (~1h).
- **Token rotation mid-pull**: kubelet uses the Secret only at pull *start*
  to mint the bearer; once the layer transfer begins, expiry mid-stream
  does not abort.
- **Audience mapper missing on `cluster-puller`**: every pull fails 401
  with no helpful logs. Verify the AT contains `zot-registry` in `aud`:
  ```
  curl -d 'grant_type=client_credentials...' | jq -r .access_token \
    | cut -d. -f2 | base64 -d | jq .aud
  ```
- **Realm recreation drops federated-identity links**: every brokered
  passkey user has to re-login once and accept "first broker login"
  account-link prompt. Acceptable; user count is small.

---

## 9. Out of scope for this round

- Crossplane provider-keycloak (would give true reconcile + drift
  correction for clients/IdPs/permissions); tracked but not scheduled.
- cosign / notation signature *verification* (zot has the trust extension
  enabled; we don't enforce signatures yet).
- Multi-replica zot HA (still 1 replica; data layer is Longhorn).
- Pull-through cache for upstream public registries.
