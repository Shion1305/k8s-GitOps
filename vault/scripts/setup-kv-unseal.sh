#!/bin/bash
# Setup KV Auto-Unseal for Vault HA cluster
# This script configures Vault to store its own unseal keys in a KV secret
# and allows a Kubernetes ServiceAccount to read them.
#
# Usage:
#   export VAULT_ADDR=http://vault.vault.svc.cluster.local:8200
#   export VAULT_TOKEN=hvs.xxxxx
#   export UNSEAL_KEY_1="..."
#   export UNSEAL_KEY_2="..."
#   export UNSEAL_KEY_3="..."
#   bash vault/scripts/setup-kv-unseal.sh

set -euo pipefail

if [[ -z "${UNSEAL_KEY_1:-}" ]] || [[ -z "${UNSEAL_KEY_2:-}" ]] || [[ -z "${UNSEAL_KEY_3:-}" ]]; then
  echo "Error: UNSEAL_KEY_1, UNSEAL_KEY_2, and UNSEAL_KEY_3 must be set."
  exit 1
fi

echo "=== Step 1: Enable KV Secrets Engine v2 ==="
vault secrets enable -version=2 -path=secret kv || echo "secret/ already enabled"

echo "=== Step 2: Store Unseal Keys ==="
vault kv put secret/unseal-keys \
  key1="${UNSEAL_KEY_1}" \
  key2="${UNSEAL_KEY_2}" \
  key3="${UNSEAL_KEY_3}"

echo "=== Step 3: Enable Kubernetes Auth ==="
vault auth enable kubernetes || echo "kubernetes auth already enabled"

# Configure K8s auth to use the pod's local service account token to verify others
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"

echo "=== Step 4: Create Auto-Unseal Policy ==="
vault policy write vault-unsealer - <<EOF
path "secret/data/unseal-keys" {
  capabilities = ["read"]
}
EOF

echo "=== Step 5: Create Kubernetes Role ==="
vault write auth/kubernetes/role/vault-unsealer \
  bound_service_account_names=vault-unsealer \
  bound_service_account_namespaces=vault \
  policies=vault-unsealer \
  ttl=1h

echo ""
echo "=== Setup Complete ==="
echo "The keys are stored securely in 'secret/unseal-keys'."
echo "ServiceAccount 'vault-unsealer' has been granted read access."
