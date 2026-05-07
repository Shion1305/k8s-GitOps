# Keycloak Operator Deployment

This directory contains the Keycloak deployment using the official Keycloak Operator.

## Migration from Bitnami Helm Chart

**Background:** Bitnami deprecated their free Keycloak Docker images on August 28, 2025. We migrated to the official Keycloak Operator which uses images from `quay.io/keycloak/keycloak`.

## GitOps Management

The Keycloak Operator is **fully managed by ArgoCD** via three applications:

### 1. `keycloak-crds` (sync-wave: -2)
- **Purpose**: Manages Keycloak CRDs
- **Source**: `https://github.com/keycloak/keycloak-k8s-resources.git`
- **Path**: `kubernetes/*-v1.yml` (CRD files only)
- **Version**: Tracked in `apps/keycloak-crds-app.yaml` targetRevision
- **Auto-prune**: Disabled (CRDs are never auto-deleted)

### 2. `keycloak-operator-install` (sync-wave: -1)
- **Purpose**: Deploys the Keycloak Operator
- **Source**: `https://github.com/keycloak/keycloak-k8s-resources.git`
- **Path**: `kubernetes/` (operator manifests)
- **Version**: Tracked in `apps/keycloak-operator-install-app.yaml` targetRevision
- **Auto-sync**: Enabled with self-heal

### 3. `keycloak-operator` (sync-wave: 0)
- **Purpose**: Manages Keycloak instance (CR)
- **Source**: This repository (`keycloak-operator/keycloak.yaml`)
- **Auto-sync**: Enabled with self-heal

## Keycloak Configuration

The `keycloak.yaml` custom resource defines:
- **Database**: External PostgreSQL (`keycloak.postgres-operator-deployment.svc.cluster.local`)
- **Hostname**: `keycloak.shion1305.com`
- **Routing**: envoy-gateway (`HTTPRoute keycloak-external`); legacy `keycloak.k.shion1305.com` 308-redirects to the new host via `keycloak-legacy-redirect`
- **Proxy headers**: xforwarded (Gateway terminates TLS, sets `X-Forwarded-Proto: https`)
- **Features**: token-exchange enabled
- **Resources**: 1.5Gi memory request, 4Gi limit

## Database Credentials

The operator requires a secret with `username` and `password` keys:

```bash
# Created from existing keycloak-postgres-credentials secret
kubectl create secret generic keycloak-db-secret -n keycloak \
  --from-literal=username=postgres \
  --from-literal=password=<password-from-postgres-operator>
```

## Upgrading Keycloak

**Automatic Updates via Renovate:**

Renovate automatically detects and creates PRs for new Keycloak operator versions by monitoring:
- `apps/keycloak-crds-app.yaml` - targetRevision field
- `apps/keycloak-operator-install-app.yaml` - targetRevision field

Both point to `github.com/keycloak/keycloak-k8s-resources` and use Git tags.

**Manual Update:**

To manually upgrade, edit the `targetRevision` in both files:

```bash
# Update both to the same version
vim apps/keycloak-crds-app.yaml        # Change targetRevision
vim apps/keycloak-operator-install-app.yaml  # Change targetRevision
git commit -m "chore: update Keycloak operator to vX.Y.Z"
```

ArgoCD will sync the changes automatically. The operator will then handle rolling updates of Keycloak pods.

## Realm Configuration (KeycloakRealmImport)

Realms are declared as `KeycloakRealmImport` CRs in this directory:

| File | Realm | Purpose |
|---|---|---|
| `user-realm.yaml` | `user` | Central human-user pool (passkey-only); brokered into other realms |
| `zot-realm.yaml` | `zot` | Docker registry auth (zot UI + GHA token-exchange) |
| `ynufes-tech-realm.yaml` | `ynufes-tech` | GitHub-OAuth realm for the cloudflare-grafana audience |

### Important: One-shot reconcile model

The Keycloak Operator's `KeycloakRealmImport` is **NOT continuously reconciled**.
It runs once when the realm does not exist. Once a realm exists, **subsequent
edits to the YAML are silently ignored**. This has two practical consequences:

1. **Drift is invisible.** Manual changes in the admin UI will not be flagged
   by ArgoCD as out-of-sync, because the operator does not compare live state
   against the YAML.

2. **YAML edits don't take effect** unless the realm is recreated:
   ```bash
   # Delete the import CR and the realm itself, then let ArgoCD reapply.
   # WARNING: this drops every user, federated identity, and group membership
   # in that realm. Acceptable for `zot` (federated GHA users only) and
   # `ynufes-tech` (regenerated easily). NEVER do this for `user` without
   # exporting and re-importing user data first.
   kubectl delete keycloakrealmimport <realm-name> -n keycloak
   # Then in admin UI: realm → Realm Settings → Action → Delete
   # ArgoCD will recreate the import CR; the operator will reimport.
   ```

### Operating principle

To keep YAML and live state aligned, follow this rule:

> **Any change applied via the admin UI MUST be backported to the YAML in this
> directory in the same PR.** If a change is impossible to express in the YAML
> (see "Known declarative limits" below), document it as a manual post-import
> step in the YAML's header comment.

### Known declarative limits (manual post-import steps required)

These items cannot be expressed in the `KeycloakRealmImport` shape today and
must be applied by hand after each realm (re)creation. Each is documented in
the affected realm YAML's header comment:

| Item | Where | Why declarative is impossible |
|---|---|---|
| Client secret values | All clients with `clientAuthenticatorType: client-secret` | Keycloak generates the secret on first import; we use the literal placeholder `PLACEHOLDER_REPLACE_AFTER_REALM_IMPORT` and retrieve the real value from the admin UI afterwards. Stored in Vault, synced via ESO. |
| Browser-flow IdP redirector binding | `zot`, others using brokered login | The "Identity Provider Redirector" execution must be added to the Browser flow and bound as the realm's Browser flow. Not expressible on the v2alpha1 CRD. |
| FGAP token-exchange permissions | `zot` (`gha-exchanger` ↔ `github-actions` IdP) | Stored under `realm-management.authorizationSettings`, all references are internal UUIDs unknown until import time. See [keycloak#33401](https://github.com/keycloak/keycloak/issues/33401), [keycloak#35790](https://github.com/keycloak/keycloak/issues/35790). |

Each realm YAML's header comment lists the realm-specific manual steps in
order. Always re-run those after realm recreation.

### Future: continuous reconciliation

Long-term we may move client/IdP/permission configuration to **Crossplane
provider-keycloak**, which gives true GitOps reconcile + drift correction +
native CRDs for FGAP token-exchange permissions. The realm shell (groups,
roles, scopes) would stay in `KeycloakRealmImport`. Tracked but not scheduled.

## Admin Access

Admin credentials are managed separately (not by the operator). Access the admin console at:

```
https://keycloak.shion1305.com
```

Default admin user: `admin`
Password: Stored in `keycloak-admin-credentials` secret

## Monitoring

The operator does not create ServiceMonitors by default. To enable Prometheus metrics, add to the Keycloak CR:

```yaml
spec:
  additionalOptions:
    - name: metrics-enabled
      value: "true"
```

## Troubleshooting

### Check operator logs
```bash
kubectl logs -n keycloak -l app.kubernetes.io/name=keycloak-operator
```

### Check Keycloak CR status
```bash
kubectl get keycloak keycloak -n keycloak -o yaml
```

### Check Keycloak pod logs
```bash
kubectl logs keycloak-0 -n keycloak
```

## Resources

- [Keycloak Operator Documentation](https://www.keycloak.org/operator/installation)
- [Keycloak on Kubernetes](https://www.keycloak.org/operator/basic-deployment)
- [Official Keycloak Images](https://quay.io/repository/keycloak/keycloak)
