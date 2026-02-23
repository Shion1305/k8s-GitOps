#!/bin/bash
# Setup Transit Auto-Unseal for self-referential Vault HA cluster
# This script configures the Transit secrets engine on the existing Vault cluster
# so that restarting pods can auto-unseal by contacting the active node.
#
# Prerequisites:
#   - Vault CLI installed
#   - All 3 Vault pods running and unsealed
#   - VAULT_ADDR and VAULT_TOKEN set (root token)
#
# Usage:
#   export VAULT_ADDR=http://vault.vault.svc.cluster.local:8200  (or port-forward)
#   export VAULT_TOKEN=hvs.xxxxx
#   bash setup-transit-autounseal.sh

set -euo pipefail

echo "=== Step 1: Enable Transit secrets engine ==="
vault secrets enable transit || echo "Transit already enabled"

echo "=== Step 2: Create auto-unseal encryption key ==="
vault write -f transit/keys/autounseal

echo "=== Step 3: Create auto-unseal policy ==="
vault policy write autounseal - <<EOF
path "transit/encrypt/autounseal" {
  capabilities = ["update"]
}
path "transit/decrypt/autounseal" {
  capabilities = ["update"]
}
EOF

echo "=== Step 4: Create a periodic token for auto-unseal ==="
echo "Creating an orphan periodic token (renewable, no parent dependency)..."
TRANSIT_TOKEN=$(vault token create \
  -orphan \
  -policy="autounseal" \
  -period=768h \
  -format=json | jq -r '.auth.client_token')

echo ""
echo "=== Transit Auto-Unseal Token ==="
echo "Token: ${TRANSIT_TOKEN}"
echo ""

echo "=== Step 5: Create Kubernetes Secret ==="
kubectl create secret generic vault-transit-token \
  --namespace=vault \
  --from-literal=token="${TRANSIT_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== Setup Complete ==="
echo "The transit engine is configured and the token is stored in k8s secret 'vault-transit-token'."
echo ""
echo "Next steps:"
echo "  1. Update vault/values.yaml with the seal transit stanza (already done)"
echo "  2. Apply the new config via ArgoCD or kubectl"
echo "  3. Unseal each pod with migration flag:"
echo "     kubectl exec vault-0 -n vault -- vault operator unseal -migrate <KEY>"
echo "     (repeat 3 times with different keys, then for vault-1 and vault-2)"
