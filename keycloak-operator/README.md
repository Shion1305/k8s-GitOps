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
- **Hostname**: `keycloak.k.shion1305.com`
- **Ingress**: nginx-ssl with xforwarded proxy headers
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

## Admin Access

Admin credentials are managed separately (not by the operator). Access the admin console at:

```
https://keycloak.k.shion1305.com
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
