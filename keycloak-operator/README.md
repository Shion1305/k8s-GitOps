# Keycloak Operator Deployment

This directory contains the Keycloak deployment using the official Keycloak Operator.

## Migration from Bitnami Helm Chart

**Background:** Bitnami deprecated their free Keycloak Docker images on August 28, 2025. We migrated to the official Keycloak Operator which uses images from `quay.io/keycloak/keycloak`.

## Manual Operator Installation

The Keycloak Operator and CRDs must be installed manually (ArgoCD cannot manage CRDs reliably):

```bash
# Install CRDs
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.4.7/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.4.7/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml

# Deploy Operator
kubectl -n keycloak apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.4.7/kubernetes/kubernetes.yml
```

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

To upgrade Keycloak, update the operator version in the installation commands above, then update the CRDs and operator deployment.

The operator will handle rolling updates of Keycloak pods automatically.

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
