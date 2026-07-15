#!/bin/bash
# Create the Vault policy and Kubernetes-auth role used by the vault-raft-snapshot
# CronJob (see ../raft-snapshot-cronjob.yaml). The CronJob's ServiceAccount
# (vault-snapshot in namespace vault) logs in via the kubernetes auth method and
# receives a token scoped to reading raft snapshots only.
#
# Prerequisites:
#   - Vault is unsealed and Kubernetes auth is enabled
#   - VAULT_ADDR and VAULT_TOKEN (admin) are set
#
# Usage:
#   export VAULT_ADDR=http://127.0.0.1:8200
#   export VAULT_TOKEN=<admin-token>
#   kubectl port-forward svc/vault-active 8200:8200 -n vault &
#   bash vault/scripts/setup-snapshot-role.sh

set -euo pipefail

echo "=== Creating vault-snapshot policy ==="
vault policy write vault-snapshot - <<'EOF'
# Read-only raft snapshots for the backup CronJob.
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF
echo "✓ Created policy: vault-snapshot"

echo "=== Creating vault-snapshot Kubernetes auth role ==="
vault write auth/kubernetes/role/vault-snapshot \
  bound_service_account_names=vault-snapshot \
  bound_service_account_namespaces=vault \
  policies=vault-snapshot \
  ttl=15m
echo "✓ Created role: vault-snapshot"
