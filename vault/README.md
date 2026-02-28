# Vault Configuration

This directory contains the configuration for HashiCorp Vault deployment using the official Helm chart.

## Overview

Vault is deployed in High Availability (HA) mode with Raft storage backend, providing secure secret storage and management for the cluster.

## Configuration

### values.yaml

Key configurations:

- **HA Mode**: 3 replicas with Raft storage
- **TLS**: Disabled at Vault level (terminated at ingress)
- **Ingress**: Accessible at `http://vault.k.shion1305.com` via `nginx-internal`
- **Storage**: 10Gi persistent volumes for data and audit logs (longhorn-ssd)
- **Resources**: 256Mi/250m requests, 512Mi/500m limits
- **Auto-Unseal**: KV-based sidecar auto-unseal via active node

## Access

- **UI**: <https://vault.k.shion1305.com>
- **API**: <https://vault.k.shion1305.com/v1/>
- **Internal**: <http://vault.vault.svc.cluster.local:8200>

## Operations

### Managing Secrets

```bash
# Add new shared secrets
vault kv put secret/shared/database \
  DB_HOST="postgres.internal" \
  DB_PORT="5432"

# Add environment-specific secrets
vault kv put secret/prod/api-keys \
  API_KEY="your-api-key"

# View existing secrets
vault kv list secret/shared/
vault kv get secret/shared/app
```

### Secret Rotation

```bash
# Update existing secret (ESO will sync automatically within 5m)
vault kv put secret/shared/app \
  DB_USER="appuser" \
  DB_PASSWORD="new-rotated-password"
```

### Backup & Maintenance

```bash
# Create Raft snapshot
vault operator raft snapshot save backup-$(date +%Y%m%d).snap

# Check cluster status
vault operator raft list-peers
vault status
```

## OIDC Authentication (Keycloak)

Vault can be configured for OIDC login via Keycloak:

```bash
# Port-forward to Vault and set root token
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root-token>
kubectl port-forward svc/vault-active 8200:8200 -n vault &

# Run setup script
bash vault/scripts/setup-oidc-auth.sh
```

After setup, select "OIDC" as the auth method in the Vault UI.

## Integration

Vault integrates with External Secrets Operator for automatic secret synchronization to Kubernetes namespaces. See `../external-secrets/` for ESO configuration.

## Notes

- Uses KV v2 secrets engine mounted at `secret/` path
- Configured for External Secrets Operator access via `eso-policy`
- ESO reads from `secret/shared/*` paths and distributes to namespaces
- Kubernetes auth role `eso` bound to `external-secrets` service account
