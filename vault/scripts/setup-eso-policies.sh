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

# Policy for harbor namespace (separate KV v2 engine mounted at harbor/)
vault policy write eso-harbor - <<EOF
path "harbor/data/*" {
  capabilities = ["read"]
}
path "harbor/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-harbor"

# NOTE: An `eso-harbor-broker` role for the Keycloak namespace to read
# `harbor/broker-credentials` is intentionally NOT created here. There is no
# precedent yet for ESO-managed broker client secrets in the keycloak ns
# (the existing zot-broker IdP secret is written manually into the realm via
# the Keycloak admin UI; see keycloak-operator/user-realm.yaml). If/when
# broker-secret automation is wired up via a vault-secret-store in the
# keycloak ns, add an `eso-harbor-broker` policy + role mirroring that pattern.

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

# Policy for cloudflare-grafana OIDC client credentials (separate KV v2 engine mounted at cloudflare-grafana/)
# The Grafana CR lives in the shared `monitoring` namespace; the role binds to SA `eso/monitoring`.
vault policy write eso-cloudflare-grafana - <<EOF
path "cloudflare-grafana/data/*" {
  capabilities = ["read"]
}
path "cloudflare-grafana/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-cloudflare-grafana"

# Policy for the cluster-wide zot-pull automation. Reads only the Keycloak
# `cluster-puller` service-account credentials at zot/cluster-puller.
# Consumed by the ClusterSecretStore `vault-zot-cluster-puller` (zot-pull/),
# which feeds the ClusterGenerator that mints pull bearer tokens.
vault policy write eso-cluster-puller - <<EOF
path "zot/data/cluster-puller" {
  capabilities = ["read"]
}
path "zot/metadata/cluster-puller" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-cluster-puller"

# Policy for the cluster-wide harbor-pull automation. Reads only the Harbor
# robot-account credentials at harbor/robot-puller. Consumed by the
# ClusterSecretStore `vault-harbor-pull` (harbor-pull/cluster-secret-store.yaml)
# which materializes a static dockerconfigjson Secret into harbor-pull-source
# (no token-exchange — Harbor robot creds are long-lived).
vault policy write eso-harbor-pull - <<EOF
path "harbor/data/robot-puller" {
  capabilities = ["read"]
}
path "harbor/metadata/robot-puller" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-harbor-pull"

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

# harbor
vault write auth/kubernetes/role/eso-harbor \
  bound_service_account_names=eso \
  bound_service_account_namespaces=harbor \
  policies=eso-harbor \
  ttl=1h
echo "✓ Created role: eso-harbor"

# github-app (cluster-scoped store; binds to the ESO operator SA, not a per-namespace SA)
vault write auth/kubernetes/role/eso-github-app \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-github-app \
  ttl=1h
echo "✓ Created role: eso-github-app"

# cloudflare-grafana (per-namespace pattern; SA `eso` lives in the shared `monitoring` namespace)
vault write auth/kubernetes/role/eso-cloudflare-grafana \
  bound_service_account_names=eso \
  bound_service_account_namespaces=monitoring \
  policies=eso-cloudflare-grafana \
  ttl=1h
echo "✓ Created role: eso-cloudflare-grafana"

# cluster-puller (cluster-scoped store; binds to the ESO operator SA so the
# ClusterSecretStore `vault-zot-cluster-puller` can read zot/cluster-puller
# from any namespace context the controller runs in).
vault write auth/kubernetes/role/eso-cluster-puller \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-cluster-puller \
  ttl=1h
echo "✓ Created role: eso-cluster-puller"

# harbor-pull (cluster-scoped store; binds to the ESO operator SA so the
# ClusterSecretStore `vault-harbor-pull` can read harbor/robot-puller from
# any namespace context the controller runs in).
vault write auth/kubernetes/role/eso-harbor-pull \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-harbor-pull \
  ttl=1h
echo "✓ Created role: eso-harbor-pull"

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
echo "  eso-harbor      → SA eso/harbor          → harbor/data/*"
echo "  eso-github-app  → SA external-secrets/external-secrets → github-app-shared/data/*"
echo "  eso-cloudflare-grafana → SA eso/monitoring     → cloudflare-grafana/data/*"
echo "  eso-cluster-puller → SA external-secrets/external-secrets → zot/data/cluster-puller"
echo "  eso-harbor-pull → SA external-secrets/external-secrets → harbor/data/robot-puller"
