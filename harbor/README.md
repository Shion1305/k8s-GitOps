# harbor — OCI Registry

Harbor v2.x deployed cluster-wide as the canonical container image registry. This deployment replaced the previous zot-based registry; see [Architecture decisions](#architecture-decisions) for the why.

## Overview

Harbor speaks OIDC at the application layer (unlike zot, where Envoy mediated browser auth via `SecurityPolicy.oidc`), so the integration here is comparatively simple: routes go to the chart's Services, OIDC settings are seeded into Harbor's own Postgres database from Vault, and the Keycloak `harbor` realm is the IdP.

Two hostnames front different parts of the deployment:

| Hostname | Gateway | Surface |
| --- | --- | --- |
| `harbor.shion1305.com` | `external` (public) | `/v2/` + `/service/token` only — primarily for GitHub Actions push |
| `harbor.i.shion1305.com` | `internal` (WireGuard-only) | full surface — portal, OIDC callback, `/api/`, `/v2/`, `/c/`, `/chartrepo/` |

Intended pull traffic happens from inside the cluster against the internal hostname. **However**, the `/v2/` PathPrefix on the public Gateway cannot distinguish push from pull — both verbs share the same path namespace — so any project flagged `public` in the Harbor portal is world-readable on `harbor.shion1305.com`. Treat project visibility as the access-control boundary: keep all projects private and lock project creation to admins (`project_creation_restriction=adminonly`).

## Architecture

```
                                     ┌───────────────────────────────────────────┐
                                     │             envoy-gateway                  │
                                     │                                            │
   GHA crane push ───────────────────┼─→ harbor.shion1305.com  (external)         │
   (Basic robot creds)               │     /v2/, /service/token                   │
                                     │     httproute-external.yaml                │
                                     │                                            │
   kubelet pull (in-cluster) ────────┼─→ harbor.i.shion1305.com  (internal)       │
   (Basic robot creds)               │     /v2/                                   │
                                     │     via Kyverno-injected harbor-pull       │
                                     │                                            │
   Browser portal ───────────────────┼─→ harbor.i.shion1305.com  (internal)       │
   (cookie session, OIDC)            │     /, /api/, /c/, /service/, /chartrepo/  │
                                     │     httproute-internal.yaml                │
                                     └───────────────────────────────────────────┘
                                                         │
                                                         ▼
                                ┌──────────────────────────────────────────────┐
                                │   harbor-portal (SPA)    harbor-core (API)   │
                                └──────────────────────────────────────────────┘
                                                         │
            ┌────────────────────────────────────────────┼──────────────────────────────┐
            ▼                                            ▼                              ▼
   ┌─────────────────┐                       ┌───────────────────┐         ┌────────────────────┐
   │ postgres-shared │                       │ keycloak (harbor  │         │ longhorn PVC       │
   │ user/db: harbor │                       │ realm + harbor-ui │         │ (registry blobs)   │
   │ via ESO k8s     │                       │ confidential cli) │         │                    │
   │ provider        │                       └───────────────────┘         └────────────────────┘
   └─────────────────┘                                 ▲
            ▲                                          │
            │       ┌──────────────────────────────────┴─────────────────────────────┐
            │       │                                                                │
            │       │ Vault (harbor/ KV v2 mount)                                    │
            │       │   harbor/openid-credentials   harbor/admin-password            │
            │       │   harbor/secret-key           harbor/core-secret               │
            │       │   harbor/robot-puller         harbor/robot-pusher              │
            │       │   harbor/broker-credentials   harbor/robot-pusher-aal-hack     │
            │       └────────────────────────────────────────────────────────────────┘
            │                  │
            │                  ▼ ESO (per-namespace SecretStore + ExternalSecret)
            │       ┌──────────────────────────────────────────────────────────────┐
            │       │ Kyverno ClusterPolicy `harbor-pull-injection`                │
            │       │   on Pod admission: clones harbor-pull-source/harbor-pull    │
            │       │   into Pod ns + appends to imagePullSecrets                  │
            │       └──────────────────────────────────────────────────────────────┘
```

Components and who hits what:

- **External Gateway (`envoy-gateway-system/external`)** — terminates TLS for `harbor.shion1305.com` (public). Used only by GHA push.
- **Internal Gateway (`envoy-gateway-system/internal`)** — terminates TLS for `harbor.i.shion1305.com` (WireGuard-only A record `10.130.5.21`). Used by browser, kubelet, in-cluster automation.
- **`harbor-core` Service** — Harbor's API + registry endpoints (`/v2/`, `/api/`, `/service/`, `/c/`, `/chartrepo/`).
- **`harbor-portal` Service** — static SPA bundle (`/`).
- **`postgres-shared` cluster** (in `postgres-operator-deployment`) — provides the `harbor` database and the `harbor` user, materialized into the `harbor` namespace as `harbor-db-credentials` by ESO's k8s provider (`db-secret-store.yaml` + `db-external-secret.yaml`).
- **Keycloak (`harbor` realm)** — drives OIDC for the portal. Realm imported declaratively via `keycloak-operator/harbor-realm.yaml`.
- **Vault (`harbor/` KV v2 mount)** — single source of truth for OIDC client secrets, Harbor's admin password, AES secret key, core inter-component secret, and robot-account credentials.
- **Kyverno (`harbor-pull-injection`)** — fans the cluster-wide `harbor-pull` dockerconfigjson Secret into any namespace whose Pods reference `harbor.shion1305.com/*` or `harbor.i.shion1305.com/*` images.

## Hostname split

The split between `harbor.shion1305.com` (public, push-only) and `harbor.i.shion1305.com` (internal, full surface) is intentional. See header comments in `httproute-external.yaml` and `httproute-internal.yaml` for the canonical justifications.

- **`harbor.shion1305.com` (public)** — only `/v2/` (PathPrefix) and `/service/token` (Exact) match; the SPA, `/api/`, `/c/`, and `/chartrepo/` are all unreachable. The worst case from a leaked credential here is a stolen robot-account token, not a compromised admin session. Note: `/v2/` allows both push and pull verbs, so public-visibility projects ARE world-readable — keep all projects private (see [Hostname split](#hostname-split)).
- **`harbor.i.shion1305.com` (internal)** — the SPA at `/`, `/api/`, `/service/`, `/v2/`, `/c/`, and `/chartrepo/` are all served. Two HTTPRoutes on the same hostname (`harbor-portal-internal` for `/` to `harbor-portal:80`, `harbor-core-internal` for the longer prefixes to `harbor-core:80`); Gateway API GEP-718 most-specific-path-wins handles ordering automatically.

The single redirect URI on the `harbor-ui` Keycloak client (`https://harbor.i.shion1305.com/c/oidc/callback`) reflects that there is no externally-facing portal to log into.

## Authentication flows

Three discrete flows touch Harbor. None of them go through Envoy's `SecurityPolicy.oidc` — Harbor handles OIDC natively.

### a. Browser portal login (OIDC)

```
user → https://harbor.i.shion1305.com/
     → harbor-portal (SPA) loads
     → user clicks "Login via OIDC"
     → harbor-core (302) redirect to Keycloak `harbor` realm `harbor-ui` client
     → Keycloak `harbor` realm Browser flow has Identity Provider Redirector
       pinned to alias `user` → silently redirects to `user` realm
     → user authenticates with passkey in the `user` realm
     → callback through `harbor-broker` IdP → `harbor` realm session
     → final callback to https://harbor.i.shion1305.com/c/oidc/callback
     → harbor-core stamps its own session cookie, returns to /
```

Authorization is by the `groups` claim. The `harbor-ui` client has a `groups` group-membership mapper; Harbor's `oidc_groups_claim=groups` setting maps those onto its internal projects. Adding a Keycloak user to the `harbor-admin` realm group makes them a Harbor admin on next login.

### b. In-cluster image pull (kubelet)

```
Pod in any namespace references harbor.i.shion1305.com/<repo>:<tag>
  → admission: Kyverno ClusterPolicy `harbor-pull-injection` fires
      - mutate: appends `imagePullSecrets: [{name: harbor-pull}]`
      - generate.clone: copies harbor-pull-source/harbor-pull → <pod-ns>/harbor-pull
  → kubelet reads dockerconfigjson for the harbor.i.shion1305.com host
  → kubelet → /v2/ on harbor-core
      - Harbor returns 401 + WWW-Authenticate: Bearer realm=...
      - kubelet → /service/token with Basic auth (robot creds)
      - Harbor mints a short-lived bearer token
      - kubelet retries /v2/<repo>/blobs/<digest> with the bearer
  → blob fetch
```

Robot credentials live in Vault at `harbor/robot-puller`. ESO's `ClusterExternalSecret` (`harbor-pull/cluster-external-secret.yaml`) reads them via the cluster-scoped `vault-harbor-pull` SecretStore (bound to the `external-secrets/external-secrets` SA via Vault role `eso-harbor-pull`) and templates a dockerconfigjson into `harbor-pull-source/harbor-pull`. Both `harbor.shion1305.com` and `harbor.i.shion1305.com` are listed in the dockerconfig so kubelet matches whichever form a Pod uses.

There is intentionally no ESO `ClusterGenerator` in the picture (zot needed one to refresh hourly Keycloak access_tokens). Harbor robot accounts are long-lived static credentials — yearly manual rotation is the model.

### c. GitHub Actions push (Vault JWT → robot creds → crane push)

GitHub Actions workflows push via the composite action at [`.github/actions/harbor-build-push/`](../.github/actions/harbor-build-push/). Robot credentials are NOT stored as GitHub repo Secrets — each run fetches them from Vault on demand using its GitHub OIDC token.

Each pushing GitHub owner gets its own Vault role, KV path, robot account and Harbor project. The action's `vault-role` / `vault-secret-path` inputs select which set a run uses:

| GitHub owner | Vault JWT role (`vault-role`) | Vault KV path (`vault kv` form) | Harbor project |
| --- | --- | --- | --- |
| `Shion1305`, `Shion1305Dev` | `harbor-robot-pusher` | `harbor/robot-pusher` | `shion1305` |
| `aal-hack` | `harbor-robot-pusher-aal-hack` | `harbor/robot-pusher-aal-hack` | `aal-hack` |

The `vault-secret-path` input takes the KV v2 **API** form of that path — `harbor/data/robot-pusher`, `harbor/data/robot-pusher-aal-hack` — which is also the form the Vault policy and `vault/httproute-external.yaml` allowlist use.

```
GHA workflow → mint OIDC JWT (audience = https://github.com/<owner>)
  → POST https://vault.shion1305.com/v1/auth/jwt/login {role: <owner's role>, jwt}
      - Vault validates iss, aud, repository_owner
      - Vault returns short-lived (10m) token with that role's reader policy
  → GET https://vault.shion1305.com/v1/harbor/data/<owner's robot>
      - Vault returns {username, password}
  → docker buildx → OCI-layout tarball
  → write ~/.docker/config.json with auth = base64("$HARBOR_ROBOT_USER:$HARBOR_ROBOT_TOKEN")
  → crane push /tmp/oci harbor.shion1305.com/<owner's project>/<repo>:<sha>
      - crane → POST /v2/ with Basic robot creds
      - Harbor 401 + WWW-Authenticate: Bearer realm=https://harbor.shion1305.com/service/token
      - crane → GET /service/token with Basic creds
      - Harbor mints bearer, validates project ACL
      - crane → POST /v2/.../blobs/uploads/ with Bearer
      - blob + manifest upload
  → cosign sign (keyless, Fulcio + Rekor)
```

Robot accounts themselves still exist (Harbor requires them) — they're created in Harbor's UI and the token is shown exactly once, then written to the owner's Vault KV path by hand.

The roles bind on `repository_owner` only. There is deliberately no `job_workflow_ref` pin: that claim names the caller's own workflow file, not the composite actions it loads, so no server-side claim can prove a caller went through this action. Consequently **any repo under an allowed owner with `id-token: write` can mint that owner's robot credentials.** That is why a new pushing owner gets its own role + robot + project rather than being appended to an existing role's allowlist — the per-owner split is what caps the blast radius. `Shion1305`/`Shion1305Dev` share one role because both are single-operator; `aal-hack` has other members, so it is isolated.

**Consumer guide**: see [`.github/actions/harbor-build-push/README.md`](../.github/actions/harbor-build-push/README.md) for the copy-paste caller, inputs/outputs, and troubleshooting.

## Bootstrap (first-time deployment)

Manual steps in order. None of these are declarative.

### 1. Enable the Vault KV mount

```bash
vault secrets enable -path=harbor kv-v2
```

### 2. Add the eso-harbor role

Re-run `vault/scripts/setup-eso-policies.sh` (idempotent) to apply the `eso-harbor` policy + role. This grants the `eso` ServiceAccount in the `harbor` namespace read access to `harbor/data/*`. While the script is running, also confirm the `eso-harbor-pull` role exists for the cluster-scoped `harbor-pull` automation.

### 3. Pre-seed Vault paths

Write placeholder values now; replace with real ones during steps 5 and 6.

```bash
# Bootstrap admin password (used for the very first portal login only — OIDC
# takes over after).
vault kv put harbor/admin-password password=<admin-password>

# AES key for at-rest encryption of OIDC refresh tokens, registry creds, etc.
# MUST be exactly 16 characters. Rotating it invalidates all stored encrypted
# blobs, so treat as long-lived.
vault kv put harbor/secret-key secretKey=<sixteen-char-key>

# Random string for inter-component auth (jobservice, registry, core).
vault kv put harbor/core-secret secret=<random-string>

# OIDC creds — leave as a stub for now; populated in step 5.
vault kv put harbor/openid-credentials \
  keycloak-credentials.json='{"clientid":"harbor-ui","clientsecret":"PLACEHOLDER"}'
```

### 4. Apply the ArgoCD app

Argo creates the `harbor` namespace and runs the chart. The `postgres-shared` cluster (in `postgres-operator-deployment`) already lists `harbor` in `users:` and `databases:` — the postgres-operator creates the role+DB on first reconcile and writes the credentials Secret `harbor.postgres-shared.credentials.postgresql.acid.zalan.do` into its own namespace. ESO's `harbor-db-credentials` ExternalSecret (`db-external-secret.yaml`) mirrors that Secret into the `harbor` namespace.

```bash
kubectl apply -f apps/harbor-app.yaml
kubectl get application harbor -n argocd -w
```

OIDC is **not yet wired** at this point — `oidc_client_secret` is set out-of-band by the post-sync Job in step 9. Until then, the portal will only accept the built-in `admin` account.

### 5. Resolve the Keycloak `harbor-ui` client secret

The `harbor` realm import (`keycloak-operator/harbor-realm.yaml`) ships with `secret: PLACEHOLDER_REPLACE_AFTER_REALM_IMPORT` for the `harbor-ui` confidential client. Keycloak generates the real value on first import.

```bash
# 1. Open Keycloak admin UI: https://keycloak.shion1305.com
# 2. Realm: harbor → Clients → harbor-ui → Credentials → "Client secret" → copy
# 3. Persist into Vault
vault kv put harbor/openid-credentials \
  keycloak-credentials.json='{"clientid":"harbor-ui","clientsecret":"<harbor-ui-secret>"}'
```

### 6. Resolve the `harbor-broker` IdP secret

Same pattern for the brokered IdP into the `user` realm:

```bash
# Realm harbor → Identity Providers → user → Settings → Client Secret → copy
vault kv put harbor/broker-credentials \
  client_id=harbor-broker \
  client_secret=<harbor-broker-secret>
```

Then write the same value into the `user` realm's broker client (in the Keycloak admin UI, under realm `user` → Clients → `harbor-broker` → Credentials). The `KeycloakRealmImport` v2alpha1 CRD does not reconcile this on its own.

### 7. Bind the Browser flow to the IdP redirector

In the Keycloak admin UI, realm `harbor` → Authentication → Flows → Browser → add execution **Identity Provider Redirector** at the top, **Required**, with config `Default Identity Provider = user`. Bind that flow as the realm's Browser flow. This skips the IdP-choice screen so users go straight to passkey login in the `user` realm.

### 8. Force ESO refresh

```bash
for es in harbor-oidc-credentials harbor-admin-password harbor-secret-key harbor-core-secret; do
  kubectl annotate externalsecret -n harbor "$es" force-sync="$(date +%s)" --overwrite
done
```

### 9. Trigger the post-sync OIDC Job

The `harbor-configure-oidc` Job (declared in `harbor/configure-oidc-job.yaml` as an Argo `PostSync` hook) reads `harbor-oidc-credentials.client-secret` and PUTs it to Harbor's `/api/v2.0/configurations` endpoint. This is the only OIDC setting that is NOT seeded via `core.configureUserSettings` — Harbor's `CONFIG_OVERWRITE_JSON` parser does not expand env vars, so a secret value cannot live in committed YAML.

The Job runs automatically on first sync. To re-run it (after rotating the client secret in Vault, for example):

```bash
# Sync of the harbor app re-creates the Job (BeforeHookCreation policy).
argocd app sync harbor --resource batch:Job:harbor-configure-oidc

# Or delete-and-let-Argo-recreate:
kubectl delete job -n harbor harbor-configure-oidc
```

### 10. Restart harbor-core (one-time)

`harbor-core` re-applies `configureUserSettings` on every start. After step 9 has populated the encrypted `oidc_client_secret`, a restart is unnecessary unless you need to pick up a rotated AES key or core secret:

```bash
kubectl rollout status -n harbor deploy/harbor-core
```

### 11. First portal login

Visit `https://harbor.i.shion1305.com` (WireGuard required). Log in **once** as the built-in `admin` user with the password from `harbor/admin-password`. This bootstraps the admin session; subsequent logins should go through OIDC.

### 12. Create the `shion1305` project and robot accounts

In the portal:

- **Projects → New Project**: name `shion1305`, **Public OFF** (the default; do not change). Public projects are world-readable on `harbor.shion1305.com`.
- **Configuration → System Settings → Project Creation**: `Admin Only`. Prevents non-admins from creating projects (and accidentally flipping them public).
- **Members**: add Keycloak group `harbor-admin` as project admin (after the first OIDC user is auto-onboarded — see Day 2 ops).
- **Projects → shion1305 → Robot Accounts → New Robot Account**:
  - `gha-pusher`: push + pull on Repository ONLY (uncheck artifact deletion, tag deletion, helm chart, scan, label permissions). Expiration 365 days. Save the token to Vault: `vault kv put harbor/robot-pusher username='robot$shion1305+gha-pusher' password='<token>'` — quote both values, the `$` in a robot name is otherwise expanded by your shell.
- **Administration → Robot Accounts → New Robot Account** (system-level, NOT project-level):
  - `cluster-puller`: pull on Repository ONLY, granted on every project the cluster deploys from — at first bootstrap that is just `shion1305`; each additional owner's project is added later without reissuing the token. Expiration 365 days. Save to Vault: `vault kv put harbor/robot-puller username='robot$cluster-puller' password='<token>'`.
  - It is system-level because the cluster-wide `harbor-pull` Secret carries exactly one credential pair keyed by hostname, so a project-scoped robot there would 401 on every other project's images. See [Extend the cluster puller to a new project](#extend-the-cluster-puller-to-a-new-project) for the rationale and the alternative that was rejected.

Repeat the project + pusher-robot half of this for each additional pushing GitHub owner — see [Onboard a new pushing GitHub owner](#onboard-a-new-pushing-github-owner).

ESO's `harbor-pull` `ClusterExternalSecret` will materialize the dockerconfigjson into `harbor-pull-source/harbor-pull` within `refreshInterval` (1h). To shortcut the wait:

```bash
kubectl annotate clusterexternalsecret harbor-pull external-secrets.io/force-sync="$(date +%s)" --overwrite
```

The end-to-end push + pull smoketest (GHA workflow + cluster-side `harbor-pull-smoketest` Job) lives in a follow-up PR; that PR is the verification gate before zot is decommissioned.

## Day 2 operations

### Rotate `harbor-ui` Keycloak client secret

1. Keycloak admin UI → realm `harbor` → Clients → `harbor-ui` → Credentials → Regenerate.
2. `vault kv put harbor/openid-credentials keycloak-credentials.json='{"clientid":"harbor-ui","clientsecret":"<new-secret>"}'`
3. ESO syncs within 5 minutes (or force with `kubectl annotate externalsecret -n harbor harbor-oidc-credentials force-sync="$(date +%s)" --overwrite`).
4. Re-run the `harbor-configure-oidc` Job to push the new secret into Harbor's DB:
   ```bash
   kubectl delete job -n harbor harbor-configure-oidc
   argocd app sync harbor
   ```
5. No rollout-restart needed — Harbor reads `oidc_client_secret` from the DB on every login attempt.

### Rotate Harbor admin password

1. `vault kv put harbor/admin-password password=<new-password>`
2. ESO syncs; no restart needed (Harbor reads the Secret on next admin login).

### Rotate a robot account

1. Harbor portal → New Robot Account with the same scope and permissions. Pushers are project-level (**Projects → `<project>` → Robot Accounts**); the cluster puller is system-level (**Administration → Robot Accounts**) — see [Extend the cluster puller to a new project](#extend-the-cluster-puller-to-a-new-project).
2. Save the new token.
3. `vault kv put harbor/robot-puller username=<new> password=<new-token>` (or the pusher path for the owner being rotated — `harbor/robot-pusher`, `harbor/robot-pusher-aal-hack`).
4. ESO syncs; for the puller, `harbor-pull` re-materializes within 1h. To force: `kubectl annotate clusterexternalsecret harbor-pull external-secrets.io/force-sync="$(date +%s)" --overwrite`. Pushers need no cluster-side sync — GitHub Actions reads Vault directly at job start.
5. Once running Pods have re-pulled with the new credentials, revoke the old robot in the portal.

### Onboard a new pushing GitHub owner

Each pushing owner gets its own Harbor project, robot account, Vault KV path and Vault JWT role. Do not append an owner to an existing role's `repository_owner` allowlist unless it is operated by the same person — the roles have no `job_workflow_ref` pin, so every repo under an allowed owner can mint that role's credentials (see [GitHub Actions push](#c-github-actions-push-vault-jwt--robot-creds--crane-push)).

1. **Harbor portal → Projects → New Project**: pick a lowercase project name for the owner — Harbor rejects uppercase (`[a-z0-9]+(?:[._-][a-z0-9]+)*`), so e.g. owner `Shion1305Dev` → project `shion1305`. **Public OFF.** Also set a storage quota well under the registry PVC (`harbor/values.yaml`, currently 200Gi): the pusher robot is deliberately denied delete rights and every build pushes a new SHA tag, so an unbounded third-party project can fill the shared volume. Record the chosen project name in the owner tables in this README and in [`.github/actions/harbor-build-push/README.md`](../.github/actions/harbor-build-push/README.md) — callers derive `image:` from it.
2. **Projects → `<project>` → Robot Accounts → New Robot Account**: `gha-pusher`, push + pull on Repository ONLY, 365 days. Copy the token (shown once).
3. **Vault**: `vault kv put harbor/robot-pusher-<owner> username='robot$<project>+gha-pusher' password='<token>'` — quote both values, Harbor robot names contain `$` and your shell would otherwise expand it.
4. **`vault/scripts/setup-eso-policies.sh`**: add a `harbor-robot-pusher-<owner>-reader` policy scoped to that one KV path, and a `harbor-robot-pusher-<owner>` JWT role with `bound_audiences: ["https://github.com/<owner>"]` and `bound_claims: {repository_owner: ["<owner>"], repository_owner_id: ["<numeric-id>"]}`. Get the id with `gh api users/<owner> --jq .id` (works for orgs too). The `repository_owner_id` pin is **mandatory for any owner whose GitHub account you do not control** — login names are recyclable, and the default OIDC audience is derived from the same mutable name. Copy the `harbor-robot-pusher-aal-hack` block as the template. Re-run the script (idempotent).
5. **`vault/httproute-external.yaml`**: append `/v1/harbor/data/robot-pusher-<owner>` (Exact, GET) to the public KV allowlist. The public Vault hostname only proxies explicitly listed paths, so skipping this makes the KV read 404 at Envoy even though the Vault policy is correct. ArgoCD syncs the route.
6. **Pull side** (only if the cluster deploys these images): the cluster has exactly one pull credential for the whole registry host, so the system-level puller robot needs pull on the new project too — see [Extend the cluster puller to a new project](#extend-the-cluster-puller-to-a-new-project). Read the trust note there before doing this for an owner you do not control.
7. Caller workflows pass `vault-role` / `vault-secret-path` / `image` for the new owner — see [`.github/actions/harbor-build-push/README.md`](../.github/actions/harbor-build-push/README.md).

### Extend the cluster puller to a new project

The cluster holds exactly ONE pull credential for `harbor.shion1305.com` — the `harbor-pull` dockerconfigjson Secret, templated with a single hostname-keyed entry. A project-scoped robot (`robot$<project>+<name>`) there can only serve one project's images; every other project's Pods land in `ImagePullBackOff`. So the puller is a **system-level** robot (`robot$<name>`, created under Administration, not inside a project) with pull granted on each project the cluster deploys from.

kubelet would in fact support a per-project layout — it honours path-prefixed `auths` keys such as `harbor.shion1305.com/<project>` and retries every matching credential in turn. That alternative is rejected deliberately, not for lack of support: Kyverno clones this one Secret into every Harbor-consuming namespace, so per-project robots would all ride along in the same Secret and buy no isolation, while adding a Vault path, an ESO policy stanza and a template branch per project.

If `harbor/robot-puller` currently holds a project-scoped robot, migrate it:

1. **Harbor portal → Administration → Robot Accounts → New Robot Account**: name `cluster-puller`, **System** level, Permissions: Repository **Pull** only, applied to the projects the cluster pulls from (`shion1305`, `aal-hack`). Expiration 365 days. Copy the token (shown once).
2. `vault kv put harbor/robot-puller username='robot$cluster-puller' password='<token>'`
3. `kubectl annotate clusterexternalsecret harbor-pull external-secrets.io/force-sync="$(date +%s)" --overwrite` (otherwise up to 1h of drift).
4. Confirm the credential actually rotated before revoking the old robot. Print the username only — decoding the whole dockerconfigjson would dump the robot password into your scrollback:
   ```bash
   kubectl get secret -n harbor-pull-source harbor-pull \
     -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d \
     | jq -r '.auths[].auth' | base64 -d | cut -d: -f1
   ```
   Then roll one Pod per project that has a workload and check it reaches `Running`. A project with no workload yet cannot be exercised this way — verify coverage in the robot's permission list instead (**Administration → Robot Accounts → `cluster-puller` → Edit**, or `GET /api/v2.0/robots/<id>` and read `permissions[].namespace`).
5. Revoke the old project-scoped puller in the portal.

**Back-out**: do not revoke the old robot until step 4 passes. If it fails, `vault kv put harbor/robot-puller` the old robot's credentials back and force-sync again — the old robot is still valid until you revoke it in step 5, so the rollback is a single Vault write.

Kyverno re-syncs the cloned Secret into every consumer namespace (`synchronize: true`), so already-running Pods keep their existing images and pick the new credential up on their next pull.

Once the system robot exists, adding a further project is just **Administration → Robot Accounts → `cluster-puller` → Edit → add pull on the new project**. The token does not change, so Vault and ESO stay untouched.

**Trust boundary — read before extending the puller to a third-party owner's project.** Push isolation does not imply pull isolation. Granting the cluster puller access to `<owner>`'s project means any Pod in this cluster may reference an image that owner's members produced, and there is no gate downstream: `harbor-pull-injection` matches on registry hostname only (never on the project segment), the repo has no Kyverno `verifyImages` policy, and Harbor's per-project "require signature" deployment security is not enabled — so the cosign signatures the push action produces are not verified by anything. Combined with the absent `job_workflow_ref` pin, any repo under that owner can put an image in that project.

Mitigate before, not after, extending the puller:

- Reference third-party images **by digest**, not by a mutable tag, wherever this repo deploys them.
- Or enable Harbor's per-project cosign requirement / add a Kyverno `verifyImages` rule pinning the expected Fulcio subject and issuer per project, which makes the existing signatures load-bearing.

Neither is configured today. `shion1305` is operator-only so the exposure was previously nil; `aal-hack` is the first project where it is not.

### Add a new Keycloak user as a Harbor admin

1. User signs in once via the portal (auto-onboarded thanks to `oidc_auto_onboard=true`).
2. Keycloak admin UI → realm `harbor` → Users → find the user → Groups → Join → `harbor-admin`.
3. User logs out and back in — the new `groups` claim picks up the role.

### Backup

Two stateful surfaces:

- **Postgres** — `harbor` database in the `postgres-shared` cluster, backed up by the postgres-operator's WAL-archiving + base-backup pipeline (see `postgres-shared/`).
- **Registry blobs** — Longhorn PVC `<release>-harbor-registry`, backed up by Longhorn snapshots (see `longhorn/backup-target.yaml`).

Restoring requires both — the database knows about manifests, the PVC holds the actual layer blobs.

### Upgrade Harbor chart

1. Bump `targetRevision` in `apps/harbor-app.yaml` (Renovate also automerges PRs for this).
2. Argo syncs.
3. For major-version bumps, read [goharbor/harbor-helm release notes](https://github.com/goharbor/harbor-helm/releases) for breaking changes (DB schema migrations, value-key renames).

## Troubleshooting

### "Login redirects to Keycloak then 400 invalid redirect URI"

The `harbor-ui` client's `redirectUris` doesn't include `https://harbor.i.shion1305.com/c/oidc/callback`. Check `keycloak-operator/harbor-realm.yaml` and re-import the realm if the YAML was changed (re-import requires deleting the `KeycloakRealmImport` CR — the operator silently ignores edits to existing imports; see header comment in `harbor-realm.yaml`).

### "Push fails with 'unauthorized: authentication required'"

The robot account was revoked or expired in Harbor. Check its status in the portal under the project's Robot Accounts tab. If the push instead fails with `denied: requested access to the resource is denied`, the workflow authenticated as the wrong owner's robot — the image's project segment must match the project that `vault-role` is bound to.

### "Pull fails with ImagePullBackOff"

Walk the pull pipeline:

```bash
# 1. Is the Kyverno policy installed and ready?
kubectl get clusterpolicy harbor-pull-injection -o yaml

# 2. Did ESO materialize the source Secret?
kubectl get secret -n harbor-pull-source harbor-pull

# 3. Did Kyverno clone the Secret into the consumer namespace?
kubectl get secret -n <pod-ns> harbor-pull

# 4. Did Kyverno append imagePullSecrets to the Pod?
kubectl get pod -n <pod-ns> <pod> -o yaml | grep -A1 imagePullSecrets

# 5. Has the robot account expired?
# Harbor portal → Administration → Robot Accounts → expiration column
# (the cluster puller is system-level, not under a project)

# 6. Does the puller cover this image's project?
kubectl get secret -n harbor-pull-source harbor-pull \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths[].auth' \
  | base64 -d | cut -d: -f1
```

Reading step 6: a project-scoped puller prints `robot$<project>+<name>`; a system-level one prints `robot$<name>` with no `+`. If it is project-scoped and the failing image belongs to a different project, that is the cause. If it is system-level, check that robot's permission list actually includes the failing image's project (**Administration → Robot Accounts → `cluster-puller` → Edit**, or `GET /api/v2.0/robots/<id>` and read `permissions[].namespace`). Either way the fix is in [Extend the cluster puller to a new project](#extend-the-cluster-puller-to-a-new-project).

### "Portal shows 'connection refused' or 500 on first sync"

`harbor-core` started before `harbor-oidc-credentials` was materialized. Restart:

```bash
kubectl rollout restart -n harbor deploy/harbor-core
```

### "Manifest URLs return http:// instead of https://"

Set `registry.relativeurls: true` in `harbor/values.yaml`. Harbor's registry component needs this when behind a TLS-terminating proxy (Envoy Gateway).

### "OIDC redirect goes to wrong hostname"

Harbor's `externalURL` setting (set via Helm chart values, key `externalURL`) doesn't match the hostname the user is hitting. The portal calls back to whatever `externalURL` says, regardless of the Host header it received. Set to `https://harbor.i.shion1305.com`.

## Architecture decisions

These are the WHYs that aren't obvious from the manifests.

### Why Harbor over zot

zot v2.1.16's bearer-OIDC middleware short-circuits `AuthHandler` whenever `bearer.oidc[]` is configured (`pkg/api/authn.go:65-67`), so the SPA's `authConfig` flow never gets `RelyingParties` initialized — see [project-zot/zot#4033](https://github.com/project-zot/zot/issues/4033). Working around this by mediating UI auth via Envoy's `SecurityPolicy.oidc` worked for happy-path login but ran into:

- `denyRedirect` API limitations for AJAX vs. navigation handling.
- Lua filter ordering issues for the `Basic(oidc:JWT)` → `Bearer JWT` rewrite required by containerd's challenge/retry handshake.
- An Envoy-Lua `mgmt`-response rewrite needed just to make the SPA take its auto-login branch.

Harbor solves all of this natively because it speaks OIDC at the application layer and mints its own bearer tokens for the registry protocol.

### Why robot accounts not Keycloak service-account tokens

Harbor's `/v2/` token endpoint does not validate external OIDC JWTs. It accepts either Basic auth (username/password or robot creds) or an OIDC ID token submitted to `/c/login` from a browser flow. Robot accounts are the supported CI auth model — long-lived, project-scoped, revocable from the portal.

This is the cleanest break from the zot setup: zot's GHA push used GitHub OIDC token-exchange directly, and zot's kubelet pull used a refresh-every-hour Keycloak client_credentials grant. Harbor needs neither — both flows collapse to "Basic with robot creds."

### Why hostname split

Public pull and public portal access are not requirements for this cluster. Minimizing the public attack surface to push-only — no admin UI, no `/api/`, no `/c/oidc/callback` — is cheaper than running a WAF or hardening the SPA against credential-stuffing. A leaked robot-account token is the worst case on `harbor.shion1305.com`; a compromised admin session would have been the worst case if the portal were exposed.

### Why postgres-shared instead of a dedicated cluster

Consistency with langfuse, keycloak, mlflow, openwebui — they all live in `postgres-shared`. Harbor's DB load is light (project metadata + manifest pointers, not blobs). Failure isolation against a shared cluster outage was deemed not worth the operational overhead of a second cluster.

### Why secretKey / coreSecret / adminPassword in Vault, not chart-generated

See `external-secret.yaml` header comment for the canonical version. Three reasons:

1. **Idempotency on chart upgrades** — Helm `lookup` values can churn if the release is recreated, breaking sessions and encrypted columns.
2. **Audit trail** — every value lives in Vault with version history.
3. **No Helm secret leaks** — `values.yaml` stays in git without any sensitive material; the chart only sees Secret references.

## ExternalSecrets

| ExternalSecret | Source | Vault path / k8s key | Materialized Secret | Consumer |
| --- | --- | --- | --- | --- |
| `harbor-oidc-credentials` | Vault (`harbor/`) | `harbor/openid-credentials` field `keycloak-credentials.json` | `harbor-oidc-credentials` (`client-id`, `client-secret`) | harbor-core OIDC config |
| `harbor-admin-password` | Vault (`harbor/`) | `harbor/admin-password` field `password` | `harbor-admin-password` (`HARBOR_ADMIN_PASSWORD`) | harbor-core bootstrap admin |
| `harbor-secret-key` | Vault (`harbor/`) | `harbor/secret-key` field `secretKey` | `harbor-secret-key` (`secretKey`) | harbor-core at-rest AES key |
| `harbor-core-secret` | Vault (`harbor/`) | `harbor/core-secret` field `secret` | `harbor-core-secret` (`secret`) | harbor-core inter-component auth |
| `harbor-db-credentials` | k8s (`postgres-operator-deployment`) | `harbor.postgres-shared.credentials.postgresql.acid.zalan.do` | `harbor-db-credentials` (`username`, `password`) | harbor-core external DB connection |
| `harbor-pull` (cluster-wide) | Vault (`harbor/`) | `harbor/robot-puller` fields `username`, `password` | `harbor-pull-source/harbor-pull` (dockerconfigjson) | Kyverno clone target → kubelet |

The two ServiceAccounts in the namespace (`eso` for the Vault provider, `eso-db` for the k8s provider) exist because ESO binds a SecretStore to a single auth provider; the Vault path uses Kubernetes auth bound to `eso-harbor`, while the k8s path uses the in-cluster API to read the postgres-operator's generated Secret.

## Files in this directory

| File | Purpose |
| --- | --- |
| `secret-store.yaml` | ServiceAccount `eso` + Vault `SecretStore` (Kubernetes auth role `eso-harbor`) |
| `external-secret.yaml` | Four ExternalSecrets sourcing from Vault `harbor/` |
| `db-secret-store.yaml` | ServiceAccount `eso-db` + k8s-provider `SecretStore` for `postgres-operator-deployment` |
| `db-external-secret.yaml` | ExternalSecret mirroring the postgres-operator's `harbor.postgres-shared.credentials.postgresql.acid.zalan.do` Secret into this namespace |
| `reference-grant.yaml` | Allows Gateways in `envoy-gateway-system` to attach HTTPRoutes living in this namespace |
| `httproute-external.yaml` | Public Registry-v2-only HTTPRoute on `harbor.shion1305.com` (`/v2/` + `/service/token`) |
| `httproute-internal.yaml` | Internal HTTPRoutes on `harbor.i.shion1305.com` (portal + core) |
| `configure-oidc-job.yaml` | Argo PostSync Job that PUTs `oidc_client_secret` into Harbor via `/api/v2.0/configurations` |

Cluster-wide pull credential plumbing lives outside this directory:

- `../harbor-pull-source/` — namespace holding the canonical `harbor-pull` dockerconfigjson Secret.
- `../harbor-pull/` — `ClusterSecretStore` + `ClusterExternalSecret` materializing that Secret from `harbor/robot-puller`.
- `../kyverno-policies/harbor-pull-injection.yaml` — Kyverno mutate (`imagePullSecrets`) + generate.clone (Secret fan-out) on Pod admission.

The end-to-end push/pull smoketest (GHA workflow + `harbor-pull-smoketest` Job) is intentionally NOT included in this PR — it lands in a follow-up PR after Harbor is up and running.

## References

- Harbor docs: https://goharbor.io/docs/2.15.0/
- Harbor Helm chart: https://github.com/goharbor/harbor-helm/tree/v1.19.0
- Harbor OIDC config keys: `src/lib/config/metadata/manifest.go` in [goharbor/harbor](https://github.com/goharbor/harbor)
- Keycloak realm import: `keycloak-operator/harbor-realm.yaml`
- Postgres user/db declaration: `postgres-shared/postgres-cluster.yaml`
- ESO policy + role: `vault/scripts/setup-eso-policies.sh` (`eso-harbor`, `eso-harbor-pull`)
- GHA push workflow: lands in the follow-up PR (after this one merges)
