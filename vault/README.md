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
- **Storage**: 10Gi persistent volumes for data and audit logs (longhorn-hdd-ha with 2 replicas)
- **Resources**: 256Mi/250m requests, 512Mi/500m limits
- **Auto-Unseal**: KV-based sidecar auto-unseal via active node
- **Pod Anti-Affinity**: Pods prefer to spread across different nodes for better HA

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

### Namespace-Scoped Access

Each namespace has its own Vault policy and Kubernetes auth role, scoped to only the secrets it needs:

| Vault Role | Namespace | Allowed Paths |
|------------|-----------|---------------|
| `eso` | external-secrets | `secret/data/shared/app` |
| `eso-atc` | atc | `atc/data/*` |

> **Note**: DB credentials for langfuse, openwebui, and keycloak are synced directly from the postgres-operator via ESO's Kubernetes provider (not Vault). See `../external-secrets/README.md`.

To add a new namespace with Vault access, update `vault/scripts/setup-eso-policies.sh` and run it.

## Migration to HA Storage

### Background

As of this configuration, Vault uses `longhorn-hdd-ha` StorageClass with 2 replicas for data redundancy. This provides protection against single node storage failures.

### Migrating Existing PVCs (If Needed)

**Important**: Existing Vault PVCs created with `longhorn-hdd` (1 replica) will continue to work, but won't automatically gain the 2-replica redundancy.

Changing the `StorageClass` for Vault in `values.yaml` on an existing deployment is **not** guaranteed to sync cleanly with Helm/ArgoCD. The Vault Helm chart uses a `StatefulSet`, and its `volumeClaimTemplates` are immutable; attempting to change the `storageClassName` will typically cause the StatefulSet update to fail reconciliation until it is manually recreated. To avoid this upgrade/sync failure mode, prefer updating the replica count on the underlying Longhorn volumes instead of changing the `StorageClass` for existing PVCs.

To migrate existing data volumes to 2 replicas without recreating the StatefulSet:
#### Option 1: Update Existing Volumes (Recommended)

```bash
# List current Vault volumes
kubectl get pvc -n vault

# For each PVC, update the underlying Longhorn volume replica count
kubectl patch volume.longhorn.io <pvc-volume-id> -n longhorn-system \
  --type='json' -p='[{"op": "replace", "path": "/spec/numberOfReplicas", "value": 2}]'

# Example:
kubectl patch volume.longhorn.io pvc-d07020bb-1fa6-47c4-8f51-52047149c72b -n longhorn-system \
  --type='json' -p='[{"op": "replace", "path": "/spec/numberOfReplicas", "value": 2}]'
```

Longhorn will automatically create the second replica and rebalance.

#### Option 2: Backup and Recreate (More Disruptive)

```bash
# 1. Create Raft snapshot
kubectl exec -n vault vault-0 -- vault operator raft snapshot save /tmp/backup.snap
kubectl cp vault/vault-0:/tmp/backup.snap ./vault-backup.snap

# 2. Scale down Vault
kubectl scale statefulset vault -n vault --replicas=0

# 3. Delete old PVCs (data will be deleted!)
kubectl delete pvc -n vault --all

# 4. Apply new configuration (will create PVCs with longhorn-hdd-ha)
# ArgoCD will automatically sync and recreate the StatefulSet/PVCs

# 5. Scale Vault back up (if not already reconciled) and wait for pods to be ready
# If ArgoCD does not automatically restore replicas, scale manually:
# kubectl scale statefulset vault -n vault --replicas=3
# Wait until vault-0 is Running/Ready:
# kubectl rollout status statefulset/vault -n vault
# If auto-unseal is disabled, unseal vault-0 before continuing.

# 6. Restore from snapshot (after vault-0 is ready and unsealed)
kubectl cp ./vault-backup.snap vault/vault-0:/tmp/backup.snap
kubectl exec -n vault vault-0 -- vault operator raft snapshot restore /tmp/backup.snap
```

### Storage Capacity Planning

With 2 replicas and 3 Vault pods:
- **Data volumes**: 3 × 10Gi × 2 replicas = 60Gi total
- **Audit volumes**: 3 × 10Gi × 2 replicas = 60Gi total
- **Total**: 120Gi across HDD-tagged disks

Current HDD capacity:
- `shion-ubuntu-2505`: 20TB (primary storage)
- `instance-2024-1`: 50GB (replica storage)
- `instance-k8s-proxy`: 50GB (replica storage)

**Result**: Fits comfortably with room for additional workloads.

## Notes

- Uses KV v2 secrets engine mounted at `secret/` path (and `atc/` for ATC-specific secrets)
- Per-namespace Vault policies enforce least-privilege access
- DB credentials use ESO Kubernetes provider for automatic rotation
- Non-DB secrets use per-namespace `SecretStore` + `ServiceAccount` for Vault isolation
- Longhorn `replicaAutoBalance: best-effort` ensures replicas spread across available nodes

