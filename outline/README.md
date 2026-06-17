# Outline

Self-hosted [Outline](https://www.getoutline.com/) knowledge base.

- **URL**: <https://outline.shion1305.com>
- **Namespace**: `outline`
- **Auth**: OIDC against the Keycloak `user` realm (passkey human-user pool)

## Architecture

| Concern        | Implementation                                                                 |
| -------------- | ------------------------------------------------------------------------------ |
| App            | `outlinewiki/outline` Deployment (single replica, `Recreate`) + ClusterIP Svc  |
| Database       | `outline` user/db on the shared `postgres-shared` cluster (in-cluster, no SSL) |
| Redis          | Disposable in-namespace `outline-redis` (no persistence)                       |
| File storage   | `FILE_STORAGE=local` on a 20Gi Longhorn RWO PVC at `/var/lib/outline/data`     |
| Ingress        | `HTTPRoute` on the `external` Gateway → `outline.shion1305.com`                 |
| App secrets    | Vault `secret/shared/outline` → ESO → `outline-secrets` Secret                 |
| DB credentials | postgres-operator Secret → ESO (k8s provider) → `outline-db` Secret            |

Config is split: non-secret env in `configmap.yaml` (`outline-config`),
secrets in the `outline-secrets` / `outline-db` Secrets. Schema migrations run
in an initContainer (`yarn db:migrate`) before the web container starts.

Outline is reached only via the Gateway, so no app-specific `NetworkPolicy` is
needed (the generated default-deny allows same-namespace ingress, and
`postgres-shared`'s Cilium policy lists the `outline` namespace). Egress is
open, so the pod can reach Postgres and Keycloak.

## One-time bootstrap (out-of-band, before/at first sync)

These steps handle secrets that intentionally never live in this public repo.

1. **Generate the app secrets and write them to Vault.** `OIDC_CLIENT_SECRET`
   comes from Keycloak in step 2 — write the two random keys first, then patch
   in the client secret.

   ```bash
   vault kv put secret/shared/outline \
     SECRET_KEY="$(openssl rand -hex 32)" \
     UTILS_SECRET="$(openssl rand -hex 32)" \
     OIDC_CLIENT_SECRET="PLACEHOLDER_UNTIL_STEP_2"
   ```

2. **Retrieve the Keycloak client secret.** The `outline` client is declared in
   `keycloak-operator/user-realm.yaml` with a placeholder secret that Keycloak
   replaces on import. In the admin UI: realm `user` → Clients → `outline` →
   Credentials → "Client secret". Patch it into Vault:

   ```bash
   vault kv patch secret/shared/outline OIDC_CLIENT_SECRET="<value-from-keycloak>"
   ```

3. **Register the Vault ESO policy/role** (already added to
   `vault/scripts/setup-eso-policies.sh` — re-run it, or apply just the
   `eso-outline` policy + role):

   ```bash
   bash vault/scripts/setup-eso-policies.sh
   ```

After these, ArgoCD syncs the app: ESO materializes `outline-secrets` and
`outline-db`, the initContainer migrates the schema, and the web pod starts.

## Notes

- The first user to sign in via OIDC becomes the workspace admin; subsequent
  users are added as members. Manage roles in Outline's own settings.
- The image tag is pinned and bumped by Renovate.
- To rotate `SECRET_KEY`/`UTILS_SECRET`, update Vault and restart the Deployment
  (ESO refreshes the Secret within `refreshInterval`).
