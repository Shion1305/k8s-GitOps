# External Secrets Operator Configuration

This directory contains the configuration for External Secrets Operator (ESO), which synchronizes secrets from HashiCorp Vault to Kubernetes Secrets across multiple namespaces.

## Overview

ESO provides:

- **ClusterSecretStore**: Connection configuration to Vault
- **ClusterExternalSecret**: Cross-namespace secret distribution
- **Automated synchronization**: Keeps Kubernetes Secrets in sync with Vault

## Architecture

```
Vault (secret/shared/app) 
    ↓
ClusterSecretStore (vault-cluster) 
    ↓  
ClusterExternalSecret (shared-app-credentials)
    ↓
Creates ExternalSecret in namespace-A → Secret in namespace-A
Creates ExternalSecret in namespace-B → Secret in namespace-B
```

## Configuration Files

### values.yaml

- ESO deployment configuration
- Resource limits and requests
- Webhook and cert controller settings

### cluster-secret-store.yaml

Defines connection to Vault:

- **Server**: `https://vault.k.shion1305.com`
- **Path**: `secret` (KV v2 mount)
- **Auth**: Kubernetes service account authentication
- **ServiceAccount**: `external-secrets` in `external-secrets` namespace

### cluster-external-secret.yaml

Manages cross-namespace secret distribution:

- **Target namespaces**: Labels with `secrets-sync/enabled=true`
- **Refresh interval**: 5 minutes
- **Secret name**: `shared-app-credentials`
- **Source**: `secret/shared/app` in Vault

### kustomization.yaml

Bundles the ClusterSecretStore and ClusterExternalSecret resources.

## Prerequisites

- Vault deployment with Kubernetes auth configured
- ESO service account and policy configured in Vault

## Usage

### Namespace Onboarding

To enable secret synchronization for a namespace:

```bash
# Label namespace to receive shared secrets
kubectl label namespace <namespace-name> secrets-sync/enabled=true

# Verify secret is created
kubectl get secret shared-app-credentials -n <namespace-name>
```

### View Secret Contents

```bash
# Check secret exists
kubectl get secret shared-app-credentials -n <namespace-name>

# View secret data (base64 decoded)
kubectl get secret shared-app-credentials -n <namespace-name> -o jsonpath='{.data.DB_USER}' | base64 -d
kubectl get secret shared-app-credentials -n <namespace-name> -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

### Application Consumption

Use the secret in your application deployments:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-namespace
spec:
  template:
    spec:
      containers:
      - name: app
        image: my-app:latest
        envFrom:
        - secretRef:
            name: shared-app-credentials
        # Or individual environment variables:
        # env:
        # - name: DB_USER
        #   valueFrom:
        #     secretKeyRef:
        #       name: shared-app-credentials
        #       key: DB_USER
```

## Adding New Shared Secrets

### Step 1: Add Secret to Vault

```bash
# Add new secret in Vault
kubectl exec -n vault vault-0 -- vault kv put secret/shared/new-service \
  API_KEY="api-key-123" \
  API_SECRET="api-secret-456"
```

### Step 2: Create New ClusterExternalSecret

```yaml
# new-cluster-external-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterExternalSecret
metadata:
  name: shared-new-service-credentials
spec:
  namespaceSelector:
    matchLabels:
      secrets-sync/enabled: "true"
  refreshInterval: 5m
  externalSecretSpec:
    secretStoreRef:
      name: vault-cluster
      kind: ClusterSecretStore
    target:
      name: shared-new-service-credentials
      creationPolicy: Owner
      template:
        type: Opaque
        metadata:
          labels:
            managed-by: external-secrets
    data:
    - secretKey: API_KEY
      remoteRef:
        key: shared/new-service
        property: API_KEY
    - secretKey: API_SECRET
      remoteRef:
        key: shared/new-service
        property: API_SECRET
```

### Step 3: Update Kustomization

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - cluster-secret-store.yaml
  - cluster-external-secret.yaml
  - new-cluster-external-secret.yaml  # Add new resource
```

## Troubleshooting

### Check ESO Status

```bash
# Check ESO pods
kubectl get pods -n external-secrets

# Check ClusterSecretStore status
kubectl describe clustersecretstore vault-cluster

# Check ClusterExternalSecret status
kubectl describe clusterexternalsecret shared-app-credentials

# View ESO logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets
```

### Verify Vault Connection

```bash
# Test Vault connectivity from ESO pod
kubectl exec -n external-secrets <eso-pod> -- \
  curl -k https://vault.k.shion1305.com/v1/sys/health

# Check ESO can authenticate to Vault (check logs for auth success)
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets | grep -i auth
```

### Force Secret Refresh

```bash
# Annotate ClusterExternalSecret to trigger refresh
kubectl annotate clusterexternalsecret shared-app-credentials \
  force-sync="$(date +%s)" --overwrite
```

## Security Considerations

- **Least privilege**: ESO can only read `secret/data/shared/*` in Vault
- **Namespace isolation**: Only labeled namespaces receive secrets
- **Service account binding**: ESO role bound to specific ServiceAccount
- **Token lifecycle**: Automatic token renewal and rotation

## Auto-restart on Secret Changes

To automatically restart pods when secrets change, use Stakater Reloader:

```yaml
# Add to your Deployment
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
    # Or specific secret:
    # secret.reloader.stakater.com/reload: "shared-app-credentials"
```
