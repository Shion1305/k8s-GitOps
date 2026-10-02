# Private notification dashboard

The dashboard at `https://credentials.research.shion.dev/admin` is a read-only
projection of notification review artifacts, tracked in
[application issue #156](https://github.com/Shion1305/gh-base64token-investigate/issues/156).
It provides recipient review, email previews and CSV export. It does not
register reports, create drafts, approve cases or send mail. The generation
time identifies the snapshot; it is not a live delivery ledger.

## Login and authorization

The dedicated `credential-exposure` realm delegates authentication to the
existing `user` realm. The local `shion1305` account is explicitly linked to
its source identity during import. A separate first-broker-login flow denies
unlinked identities; there is no automatic account creation, email-based
linking or local password login. No changes to the source realm's users,
browser flow or administrative permissions are needed.

The `/admin` HTTPRoute uses Envoy OIDC with the confidential
`credential-exposure-admin` client. Its callback and logout paths remain
under `/admin`. Envoy forwards the access token to the application, which
must verify its RS256 signature, issuer, audience, expiry and exact subject
against the private owner allowlist before reading any data. The allowlist
uses the **local target-realm subject**, not the source realm's subject.
Keycloak login alone does not authorize dashboard access. There is no Basic
authentication fallback; public routes keep their existing behavior.

## Keycloak bootstrap

Create the confidential `credential-exposure-broker` client in the existing
`user` realm through the Admin UI/API. Enable only Standard flow; disable
implicit flow, direct access grants and service accounts. Disable full scope
and retain only the built-in `basic` and `profile` default client scopes.
Use this exact redirect URI:

`https://keycloak.shion1305.com/realms/credential-exposure/broker/user/endpoint`

Its web origin is `https://keycloak.shion1305.com`. No administrator role or
service account is required. Capture its generated client secret privately.
Creating an Identity Provider does not create this source client.

Before merging, create `credential-exposure-realm-bootstrap` in namespace
`keycloak` from private files, with these keys:

| Secret key | Use |
| --- | --- |
| `dashboard-client-secret` | Generated secret for the target dashboard client; also used by Envoy |
| `broker-client-secret` | Secret of the source realm's dedicated broker client |
| `owner-subject` | Generated UUID for the local target-realm `shion1305` user; also the app allowlist |
| `source-subject` | Verified existing `shion1305` subject in realm `user` |

The new `KeycloakRealmImport` references these keys through supported Secret
placeholders. No values or personal user IDs belong in Git. Retain the
private bootstrap records for recovery. The existing Keycloak namespace
Vault store can read only the legacy `secret/shared/keycloak` path; this
change does not broaden that policy or write unrelated credentials.

The import creates the new realm, browser/broker flows, linked owner and
dashboard client with an explicit access-token audience mapper. It is
creation-only: it will not update an existing realm. Later changes require
the Admin UI/API; do not delete a realm to make an edited import take effect.
The new preview client-operator feature is not required. See
[Keycloak realm import and placeholders](https://www.keycloak.org/operator/realm-import).

## Application secrets and review data

The existing `gh-leaked-tokens` namespace SecretStore `vault` reads the
KV v2 mount `gh-leaked-tokens/`. Provision these two independent paths:

| Vault path | Properties | Kubernetes Secret |
| --- | --- | --- |
| `gh-leaked-tokens/credential-exposure-admin-oidc` | `client_id`, `client_secret`, `allowed_subjects` | `credential-exposure-admin-oidc` |
| `gh-leaked-tokens/credential-exposure-admin-review` | `dashboard` (JSON string) | `credential-exposure-admin-review` |

The client ID is `credential-exposure-admin`; its secret must match
`dashboard-client-secret` above. `allowed_subjects` contains the local owner
UUID. ESO produces `client-id`, `client-secret` and `allowed-subjects` keys;
only the last is passed to the app as `ADMIN_OIDC_ALLOWED_SUBJECTS`. The app's
issuer and audience are explicit deployment configuration. The application
does not receive the OIDC client secret or any broader database credentials.

The review property becomes `/var/run/notification-dashboard/dashboard.json`,
selected by `ADMIN_DASHBOARD_DATA_FILE`. The directory mount is read-only,
uses mode `0440` and existing Pod group `10001`, and does not use `subPath`.
The app's Secret reference and data volume are optional so missing dashboard
configuration does not stop public pages. The app must deny dashboard access
without its allowlist or a valid review export.

Use an authenticated operator connection to `https://vault.i.shion1305.com`
or a local port-forward to `svc/vault-active` in namespace `vault`. Read
credentials and exported JSON from private files and send JSON on stdin;
never include them in command arguments, Git, images or terminal output.
Initial writes use KV v2 compare-and-set version `0` to refuse replacement
of an existing path. Later refreshes must preserve other properties and use
the current version as the compare-and-set guard.

Keep the minimal export below 900 KiB; each Kubernetes Secret is limited to
1 MiB. ESO checks Vault every five minutes; directory-mounted Secret updates
then reach the Pod eventually. The app reads the snapshot per request. A
changed allowlist needs an approved restart because it is an environment
variable; a JSON-only refresh does not. See the
[Kubernetes Secret update rules](https://kubernetes.io/docs/concepts/configuration/secret/).

## Detailed evidence files

The evidence extension tracked in
[application issue #175](https://github.com/Shion1305/gh-base64token-investigate/issues/175)
keeps detailed observations separate from the compact dashboard index. The
`notification-evidence` projected volume mounts 27 dedicated Secrets,
`credential-exposure-admin-evidence-01` through
`credential-exposure-admin-evidence-27`, read-only at
`/var/run/notification-evidence`, selected by `ADMIN_DASHBOARD_EVIDENCE_DIR`.
It uses mode `0440`, the existing Pod group `10001`, and no `subPath`.
Every source is optional so an unprovisioned shard does not prevent public
pages from starting. The existing owner authorization still precedes
evidence reads; missing or inconsistent files make evidence unavailable.

Each ExternalSecret extracts one same-name Vault path under the existing
`gh-leaked-tokens/` KV v2 mount through the namespace SecretStore `vault`.
The reviewed packing plan places `manifest.json` in shard `01` only.
Each path contains a flat map of filenames to UTF-8 JSON strings. ESO uses
[`dataFrom.extract`](https://external-secrets.io/latest/guides/all-keys-one-secret/)
to preserve those keys; it does not generate or transform evidence. No new
Vault policy, Kubernetes RBAC, database grant or OIDC setting is required.

All files appear directly in the projected directory. `manifest.json` must
occur in exactly one Secret, and every evidence filename must be unique
across all sources. Kubernetes projects these sources into a shared path;
it does not validate the application's evidence membership or digests. The
private export and publication checks must reject duplicate filenames,
unexpected keys and missing or extra files before any write. Filenames,
case data and private export artifacts do not belong in this repository.

The app limits each evidence part to 256 KiB and the manifest to 900 KiB.
The publication plan must also bound each complete Secret conservatively:
the serialized base64-encoded `data` map plus at least 1 KiB reserved for
metadata must remain at or below 900 KiB. The dashboard index retains its
separate bound. Check the actual exported bytes, not estimates or only the
sum of unencoded values; adding shards requires a reviewed manifest change.

The manifest binds the exact dashboard SHA-256 and each case/member/file.
After approval, publish and verify the evidence-only shards first, then
the shard containing the manifest, and update the dashboard index last.
Use version-0 CAS for new paths and the current version for replacements.
ESO and the two mounted directories refresh independently; this order
reduces inconsistent reads but is not an atomic publication mechanism.
The app must reject any mixed generation until all bound bytes match.
An evidence-only update to an unchanged index still requires those checks.

After an approved deployment/publication, verify ExternalSecret readiness
and the mounted file count, bounds and digests without printing contents.
Verify owner-only evidence in the browser and fail-closed behavior with a
missing or mismatched fixture. Check that public pages remain healthy.
An environment or projected-source-list change requires a Pod rollout;
file-only updates arrive through the directory mount. See
[Kubernetes projected volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/).
Preparing these manifests does not publish data, establish successful live
checks, activate disclosure delivery or authorize credential replay.

## Release checks

Publish the reviewed application image and provision the private bootstrap
inputs before merging. Argo CD reconciles the realm and application changes
independently; keep the dashboard unavailable until both are ready. No
Gateway listener, database privilege or request-log changes are included.

Check RealmImport completion, both ExternalSecrets, the admin HTTPRoute and
SecurityPolicy conditions without printing Secret contents. After the
approved rollout, verify the actual browser redirect/login/callback and
owner access. An unlinked source identity must be denied, and a signed token
for the wrong issuer, audience or subject must disclose no table, preview or
CSV. Missing/invalid configuration must remain closed; public pages and
existing report routes must still work. Local manifest validation does not
prove those live identity-provider or application checks.
