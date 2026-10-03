# Private notification dashboard

This draft prepares the database-backed dashboard at
`https://credentials.research.shion.dev/admin`, tracked in
[GitOps issue #684](https://github.com/Shion1305/k8s-GitOps/issues/684).
It uses saved review decisions and previews plus current stored operator evidence
from `research_gh_leaks`. It does not register reports, create drafts, approve
cases or send mail. A database observation is not a delivery confirmation or
permission to share evidence. This revision is not a record of deployment,
secret publication, successful owner login or production database changes.

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

## Dashboard database credential

The existing namespace SecretStore `vault` reads the KV v2 mount
`gh-leaked-tokens/`. The application resources use two independent paths:

| Vault path | Properties | Kubernetes Secret |
| --- | --- | --- |
| `gh-leaked-tokens/credential-exposure-admin-oidc` | `client_id`, `client_secret`, `allowed_subjects` | `credential-exposure-admin-oidc` |
| `gh-leaked-tokens/credential-exposure-admin-db` | `username`, `password` | `credential-exposure-admin-db` |

The OIDC client ID remains `credential-exposure-admin`, and `allowed_subjects`
contains the local target-realm owner UUID. ESO exposes the same `client-id`,
`client-secret` and `allowed-subjects` keys as before; only the allowlist reaches
the application. This revision does not change the realm, HTTPRoute,
SecurityPolicy, public survey/report credentials or their grants.

The new ExternalSecret uses the existing Vault store and URL-encodes the
username/password into a `DB_URL` targeting
`postgres-shared.postgres-operator-deployment.svc.cluster.local:5432/research_gh_leaks`.
The Deployment maps that key to `ADMIN_DASHBOARD_DB_URL` with an optional Secret
reference. Missing OIDC configuration, credential or database projections must
deny `/admin` access while public routes remain available. The runtime has no
fallback to the pipeline login, recipient application logins or artifact files.

Use a dedicated unprivileged LOGIN such as the reviewed
`credential_dashboard_app`, granted only the `credential_dashboard_read` NOLOGIN
role by the application's provisioning script. The dashboard role can connect,
use the `dashboard_read` schema and execute its list, case-detail and evidence
functions. It receives no direct raw-table reads, questionnaire access, writes,
role administration or ownership. The provisioning script rejects principals
with broader direct, inherited or PUBLIC privileges across non-system schemas,
including unrelated executable SECURITY DEFINER functions. Any required PUBLIC
privilege policy adjustment is a separate administrator decision; the script
does not weaken unrelated privileges itself. It cannot create a login or
supply a password; create/manage that dedicated credential through the approved
private administrator process. No operator-generated PostgreSQL Secret or
cross-namespace credential-reader RBAC is added by this revision.

Provision Vault only after the login and grants have been verified. Use private
files and an authenticated operator connection; do not place credential values
in Git, command arguments, images or terminal output. New KV paths require
compare-and-set version `0`; rotations preserve properties and use the current
version. ESO refreshes every five minutes, but environment values require a Pod
restart after credential changes. This preparation performs no Vault or cluster
write and does not generate credentials.

## Reviewed rollout order

Argo CD automatically reconciles a merged change. Keep this PR in Draft and the
issue In Progress until application integration, preservation checks and the
following prerequisites are reviewed. Do not merge configuration ahead of its
compatible application image and database prerequisites.

1. **Record the baseline and retain artifacts.** Record the current image digest,
   application/GitOps revisions and database backup reference privately. Retain
   original reviewed dashboard, membership manifest, source artifacts and saved
   preview bytes, including the former transport's private backups. Removing
   dataset ExternalSecrets can prune their Kubernetes targets; it must not delete
   private source files or Vault backups. These sources remain recovery evidence,
   not a runtime fallback.
2. **Apply the application migrations.** From the reviewed application checkout,
   apply migrations `0018_dashboard` and `0019_dashboard_projections` to the same
   `research_gh_leaks` database using the existing privileged migration procedure.
   Verify both revisions and the expected tables/read functions. Do not create a
   second dashboard database or change the public recipient connections.
3. **Rehearse the pinned offline import.** Use a separate privileged operator
   connection through `DASHBOARD_IMPORT_DB_URL`; never expose it to the web Pod.
   Run the maintained importer from the application checkout with the reviewed
   private inputs and their SHA-256 values:

   ```sh
   uv run python scripts/import_dashboard.py \
     --dashboard '<private-dashboard-path>' \
     --dashboard-sha256 '<dashboard-sha256>' \
     --membership-manifest '<private-membership-manifest-path>' \
     --membership-sha256 '<membership-sha256>' \
     --source-root '<private-original-source-root>'
   ```

   Repeat `--source-root` when required. The default run rolls back. Pin the
   current **282 saved cases** by their original case IDs and exact memberships;
   compare all review flags, contacts, workflow states, source digests and saved
   HTML/plain-text previews. Counts alone do not prove preservation. Resolve every
   mismatch before using the same pinned arguments with explicit `--apply`.
   Recheck the committed import and an idempotent rehearsal afterward. New live
   candidates must not silently replace or reapprove those saved cases.
4. **Provision and verify the dedicated read role.** After the unprivileged LOGIN
   exists, use an administrator session to run the reviewed application script.
   Its variables are `dashboard_login` and optional `dashboard_role` (default
   `credential_dashboard_read`). For the existing primary-Pod socket procedure:

   ```sh
   kubectl -n postgres-operator-deployment exec -i "$POSTGRES_PRIMARY_POD" -- \
     psql -X -U postgres -d research_gh_leaks -v ON_ERROR_STOP=1 \
     -v dashboard_login=credential_dashboard_app \
     -v dashboard_role=credential_dashboard_read -f - \
     < survey/scripts/provision_dashboard_access.sql
   ```

   Verify the read functions work as that login and raw tables, private projection
   objects, questionnaire data and writes are denied. Do not reuse an application,
   pipeline or migration login merely because it can execute the functions.
5. **Publish the reviewed credential and application image.** Populate only the
   new Vault credential path through the approved private process. Review the
   ExternalSecret mapping without printing credential contents; its Ready
   condition is checked after reconciliation in step 6. Publish the exact tested
   database-dashboard image and record its
   digest. The local application Deployment and this Deployment must agree before
   cutover; application runtime integration is recorded at
   [`a378d8b`](https://github.com/Shion1305/gh-base64token-investigate/commit/a378d8b3607261c074d4b7b8f62bc41dc7b6bdd0).
6. **Cut over configuration together.** Merge only the reviewed GitOps revision
   paired with the compatible image. Its Deployment consumes the dedicated
   database Secret and removes both dataset transports and all 27 evidence
   ExternalSecrets. Verify ESO readiness, roll the Pod to receive the environment
   value and check the running image digest. Publishing `latest` alone does not
   restart an existing Pod. Retain old private artifacts throughout the rollout.
7. **Verify restricted behavior and preservation.** Check real owner login,
   outsider/wrong-issuer/wrong-audience denial and authentication before list,
   detail, CSV, raw preview and evidence queries. Compare the pinned 282 saved
   cases, independent approval/workflow states and version-pinned preview bytes.
   Verify filters, complete CSV export, selected details outside the current page,
   evidence pagination and honest unknown timestamps/statuses. Confirm that a
   missing dedicated credential or failed projection returns a generic unavailable
   response with no file fallback. Recheck public pages and recipient report/survey
   routes. Successful rendering does not approve outreach or credential replay.

Local Kustomize/schema renders and synthetic application tests cannot establish
these live database, identity-provider or application checks. Keep release approval
separate from the retained review artifacts' recipient/evidence approvals.

## Rollback order

1. Stop further cutover/import/credential changes and preserve the failing release
   references and aggregate checks. Do not alter accepted case IDs or rewrite
   original artifacts to make a comparison pass.
2. Keep `/admin` unavailable while diagnosing by removing its dedicated database
   environment reference in a reviewed rollback revision, then roll the Pod.
   Preserve OIDC protection and all public recipient configuration. This is an
   intentional availability loss, not permission to fall back to another DB login
   or stale files.
3. If the application image must roll back, pair its recorded digest with a reviewed
   compatible configuration. A pre-database image will remain unavailable at
   `/admin` with these dataset mounts removed; do not recreate runtime artifact
   transport implicitly. Restoring an older file-based release would require a
   separate explicit review of that release and its retained source generation.
4. Leave migrations `0018`/`0019`, imported history and private source artifacts
   intact. Do not downgrade or delete tables as an incident shortcut. Stop all
   affected Pods before revoking or rotating the dedicated read login. Existing
   survey/report grants and the operator import credential remain separate.
5. Rehearse the forward fix with the same pinned inputs and restricted role,
   compare the saved cases again, then repeat configuration/owner-access checks
   before re-enabling the dashboard. Retirement of obsolete private backups is a
   separate retention decision after successful rollout and rollback review.
