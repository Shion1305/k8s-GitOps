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

# Policy for lumos-bot namespace (separate KV v2 engine mounted at lumos-bot/)
vault policy write eso-lumos-bot - <<EOF
path "lumos-bot/data/*" {
  capabilities = ["read"]
}
path "lumos-bot/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-lumos-bot"

# Policy for freqtrade namespace (separate KV v2 engine mounted at freqtrade/)
vault policy write eso-freqtrade - <<EOF
path "freqtrade/data/*" {
  capabilities = ["read"]
}
path "freqtrade/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-freqtrade"

# Policy for cert-manager namespace (system/ KV v2 mount, cert-manager only)
vault policy write eso-cert-manager - <<EOF
path "system/data/cert-manager" {
  capabilities = ["read"]
}
path "system/metadata/cert-manager" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-cert-manager"

# Policy for zot namespace (separate KV v2 engine mounted at zot/)
vault policy write eso-zot - <<EOF
path "zot/data/*" {
  capabilities = ["read"]
}
path "zot/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-zot"

# Policy for github-app shared credentials (cluster-scoped store, separate KV v2 engine mounted at github-app-shared/)
vault policy write eso-github-app - <<EOF
path "github-app-shared/data/*" {
  capabilities = ["read"]
}
path "github-app-shared/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-github-app"

echo ""
echo "=== Creating namespace-scoped Kubernetes auth roles ==="

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

# Lumos Bot
vault write auth/kubernetes/role/eso-lumos-bot \
  bound_service_account_names=eso \
  bound_service_account_namespaces=lumos-bot \
  policies=eso-lumos-bot \
  ttl=1h
echo "✓ Created role: eso-lumos-bot"

# Freqtrade
vault write auth/kubernetes/role/eso-freqtrade \
  bound_service_account_names=eso \
  bound_service_account_namespaces=freqtrade \
  policies=eso-freqtrade \
  ttl=1h
echo "✓ Created role: eso-freqtrade"

# cert-manager
vault write auth/kubernetes/role/eso-cert-manager \
  bound_service_account_names=eso \
  bound_service_account_namespaces=cert-manager \
  policies=eso-cert-manager \
  ttl=1h
echo "✓ Created role: eso-cert-manager"

# zot
vault write auth/kubernetes/role/eso-zot \
  bound_service_account_names=eso \
  bound_service_account_namespaces=zot \
  policies=eso-zot \
  ttl=1h
echo "✓ Created role: eso-zot"

# github-app (cluster-scoped store; binds to the ESO operator SA, not a per-namespace SA)
vault write auth/kubernetes/role/eso-github-app \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-github-app \
  ttl=1h
echo "✓ Created role: eso-github-app"

echo ""
echo "=== Removing old broad policy ==="
vault policy delete eso-policy 2>/dev/null && echo "✓ Deleted old policy: eso-policy" || echo "ⓘ Policy eso-policy not found (already removed)"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Per-namespace roles created:"
echo "  eso-langfuse    → SA eso/langfuse        → secret/data/shared/langfuse"
echo "  eso-openwebui   → SA eso/openwebui       → secret/data/shared/openwebui"
echo "  eso-keycloak    → SA eso/keycloak        → secret/data/shared/keycloak"
echo "  eso-atc         → SA eso/atc             → atc/data/*"
echo "  eso-lumos-bot   → SA eso/lumos-bot       → lumos-bot/data/*"
echo "  eso-freqtrade   → SA eso/freqtrade       → freqtrade/data/*"
echo "  eso-cert-manager→ SA eso/cert-manager    → system/data/cert-manager"
echo "  eso-zot         → SA eso/zot             → zot/data/*"
echo "  eso-github-app  → SA external-secrets/external-secrets → github-app-shared/data/*"
