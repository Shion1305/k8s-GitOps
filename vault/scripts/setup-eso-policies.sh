#!/bin/bash
# Setup scoped ESO policies and Kubernetes auth roles for namespace isolation.
#
# This replaces the broad "eso-policy" (secret/data/*) with per-namespace policies,
# so each namespace can only read its own Vault secrets.
#
# Prerequisites:
#   - Vault is unsealed and Kubernetes auth is already enabled
#   - VAULT_ADDR and VAULT_TOKEN are set
#
# Usage:
#   export VAULT_ADDR=http://127.0.0.1:8200
#   export VAULT_TOKEN=hvs.xxxxx
#   kubectl port-forward svc/vault-active 8200:8200 -n vault &
#   bash vault/scripts/setup-eso-policies.sh

set -euo pipefail

echo "=== Creating namespace-scoped ESO policies ==="

# Policy for ClusterExternalSecret (shared/app only)
vault policy write eso-shared - <<EOF
path "secret/data/shared/app" {
  capabilities = ["read"]
}
path "secret/metadata/shared/app" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-shared"

# Policy for langfuse namespace
vault policy write eso-langfuse - <<EOF
path "secret/data/shared/langfuse" {
  capabilities = ["read"]
}
path "secret/metadata/shared/langfuse" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-langfuse"

# Policy for openwebui namespace
vault policy write eso-openwebui - <<EOF
path "secret/data/shared/openwebui" {
  capabilities = ["read"]
}
path "secret/metadata/shared/openwebui" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-openwebui"

# Policy for keycloak namespace
vault policy write eso-keycloak - <<EOF
path "secret/data/shared/keycloak" {
  capabilities = ["read"]
}
path "secret/metadata/shared/keycloak" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-keycloak"

# Policy for atc namespace (separate KV v2 engine mounted at atc/)
vault policy write eso-atc - <<EOF
path "atc/data/*" {
  capabilities = ["read"]
}
path "atc/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-atc"

echo ""
echo "=== Creating namespace-scoped Kubernetes auth roles ==="

# Update existing "eso" role to use scoped policy (ClusterExternalSecret only)
vault write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-shared \
  ttl=1h
echo "✓ Updated role: eso (scoped to eso-shared)"

# Langfuse
vault write auth/kubernetes/role/eso-langfuse \
  bound_service_account_names=eso \
  bound_service_account_namespaces=langfuse \
  policies=eso-langfuse \
  ttl=1h
echo "✓ Created role: eso-langfuse"

# OpenWebUI
vault write auth/kubernetes/role/eso-openwebui \
  bound_service_account_names=eso \
  bound_service_account_namespaces=openwebui \
  policies=eso-openwebui \
  ttl=1h
echo "✓ Created role: eso-openwebui"

# Keycloak
vault write auth/kubernetes/role/eso-keycloak \
  bound_service_account_names=eso \
  bound_service_account_namespaces=keycloak \
  policies=eso-keycloak \
  ttl=1h
echo "✓ Created role: eso-keycloak"

# ATC
vault write auth/kubernetes/role/eso-atc \
  bound_service_account_names=eso \
  bound_service_account_namespaces=atc \
  policies=eso-atc \
  ttl=1h
echo "✓ Created role: eso-atc"

echo ""
echo "=== Removing old broad policy ==="
vault policy delete eso-policy 2>/dev/null && echo "✓ Deleted old policy: eso-policy" || echo "ⓘ Policy eso-policy not found (already removed)"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Per-namespace roles created:"
echo "  eso          → SA external-secrets/external-secrets → secret/data/shared/app"
echo "  eso-langfuse → SA eso/langfuse                      → secret/data/shared/langfuse"
echo "  eso-openwebui→ SA eso/openwebui                     → secret/data/shared/openwebui"
echo "  eso-keycloak → SA eso/keycloak                      → secret/data/shared/keycloak"
echo "  eso-atc      → SA eso/atc                           → atc/data/*"
