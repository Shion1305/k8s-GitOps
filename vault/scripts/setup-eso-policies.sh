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

# Policy for outline namespace
vault policy write eso-outline - <<EOF
path "secret/data/shared/outline" {
  capabilities = ["read"]
}
path "secret/metadata/shared/outline" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-outline"

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

# Policy for claude-code namespace (separate KV v2 engine mounted at claude-code/)
vault policy write eso-claude-code - <<EOF
path "claude-code/data/*" {
  capabilities = ["read"]
}
path "claude-code/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-claude-code"

# Policy for scalable-llm namespace (separate KV v2 engine mounted at scalable-llm/)
vault policy write eso-scalable-llm - <<EOF
path "scalable-llm/data/*" {
  capabilities = ["read"]
}
path "scalable-llm/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-scalable-llm"

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

# Policy for nc-press-chotatsu namespace (separate KV v2 engine mounted at nc-press-chotatsu/)
vault policy write eso-nc-press-chotatsu - <<EOF
path "nc-press-chotatsu/data/*" {
  capabilities = ["read"]
}
path "nc-press-chotatsu/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-nc-press-chotatsu"

# Policy for fde-knowledge-engine namespace (separate KV v2 engine mounted at fde-knowledge-engine/)
vault policy write eso-fde-knowledge-engine - <<EOF
path "fde-knowledge-engine/data/*" {
  capabilities = ["read"]
}
path "fde-knowledge-engine/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-fde-knowledge-engine"

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

# Policy for the clearnet-website-monitoring namespace. Reads the list of
# domains the exporter probes — kept in Vault (not the public k8s-GitOps
# repo) because the domain list itself is sensitive in the takedown-research
# context.
vault policy write eso-clearnet-website-monitoring - <<EOF
path "clearnet-website-monitoring/data/*" {
  capabilities = ["read"]
}
path "clearnet-website-monitoring/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "✓ Created policy: eso-clearnet-website-monitoring"

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

# Outline
vault write auth/kubernetes/role/eso-outline \
  bound_service_account_names=eso \
  bound_service_account_namespaces=outline \
  policies=eso-outline \
  ttl=1h
echo "✓ Created role: eso-outline"

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

# claude-code
vault write auth/kubernetes/role/eso-claude-code \
  bound_service_account_names=eso \
  bound_service_account_namespaces=claude-code \
  policies=eso-claude-code \
  ttl=1h
echo "✓ Created role: eso-claude-code"

# scalable-llm
vault write auth/kubernetes/role/eso-scalable-llm \
  bound_service_account_names=eso \
  bound_service_account_namespaces=scalable-llm \
  policies=eso-scalable-llm \
  ttl=1h
echo "✓ Created role: eso-scalable-llm"

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

# nc-press-chotatsu
vault write auth/kubernetes/role/eso-nc-press-chotatsu \
  bound_service_account_names=eso \
  bound_service_account_namespaces=nc-press-chotatsu \
  policies=eso-nc-press-chotatsu \
  ttl=1h
echo "✓ Created role: eso-nc-press-chotatsu"

# fde-knowledge-engine
vault write auth/kubernetes/role/eso-fde-knowledge-engine \
  bound_service_account_names=eso \
  bound_service_account_namespaces=fde-knowledge-engine \
  policies=eso-fde-knowledge-engine \
  ttl=1h
echo "✓ Created role: eso-fde-knowledge-engine"

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

# clearnet-website-monitoring
vault write auth/kubernetes/role/eso-clearnet-website-monitoring \
  bound_service_account_names=eso \
  bound_service_account_namespaces=clearnet-website-monitoring \
  policies=eso-clearnet-website-monitoring \
  ttl=1h
echo "✓ Created role: eso-clearnet-website-monitoring"

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
echo "=== Configuring GitHub Actions OIDC (JWT auth) for CI pushes ==="

# JWT auth method for GitHub Actions OIDC tokens. This is separate from the
# Kubernetes auth method above — Kubernetes auth is for in-cluster ESO,
# JWT auth is for external CI runners (GitHub-hosted) that mint short-lived
# OIDC tokens via id-token: write. Vault verifies the token signature against
# GitHub's JWKS (oidc_discovery_url), confirms the issuer, then matches the
# token's claims against a per-role bound_claims allowlist.
#
# Reachable externally via https://vault.shion1305.com (path-allowlisted in
# vault/httproute-external.yaml). The internal hostname stays unreachable
# from GitHub Actions.
vault auth enable -path=jwt jwt 2>/dev/null && echo "✓ Enabled auth method: jwt" || echo "ⓘ JWT auth method already enabled"

vault write auth/jwt/config \
  oidc_discovery_url="https://token.actions.githubusercontent.com" \
  bound_issuer="https://token.actions.githubusercontent.com"
echo "✓ Configured JWT auth: oidc_discovery_url=token.actions.githubusercontent.com"

# Policy: read-only on harbor/robot-pusher (the dynamic Harbor robot password
# lives at this single KV v2 path; the leaf is wrapped per KV v2 conventions
# under /data/). Scope is intentionally a single Exact path — leaking the
# CI token must not let the caller wander other harbor/* keys.
vault policy write harbor-robot-pusher-reader - <<EOF
path "harbor/data/robot-pusher" {
  capabilities = ["read"]
}
EOF
echo "✓ Created policy: harbor-robot-pusher-reader"

# Role: accepts GitHub OIDC tokens minted from any repo under the
# `Shion1305` or `Shion1305Dev` owners. The previous incarnation of this
# role additionally pinned `bound_claims.job_workflow_ref` to the (now
# removed) reusable workflow at .github/workflows/harbor-build-push.yaml,
# but the migration to a composite action makes that pin unworkable:
# `job_workflow_ref` only describes the calling workflow file, not which
# composite actions it loads, so the value differs per caller and cannot
# be enumerated in a server-side allowlist. The blast radius is now
# capped by the owner allowlist alone — every repo under either owner
# that has `id-token: write` on a job can mint Harbor push creds, even
# without `uses:`-ing the composite action. Accepted intentionally: both
# owners are single-operator and the Harbor robot is scoped to the
# `shion1305` project only.
# Reference: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect
#
# bound_audiences: GitHub's @actions/core.getIDToken() defaults the `aud`
# claim to `https://github.com/<repository_owner>` when no audience is
# passed. Listing both owners here means caller workflows do NOT need to
# set `jwtGithubAudience`.
#
# user_claim=repository → audit logs identify the caller as `owner/repo`,
# which is the readable form Vault operators want.
#
# token_ttl=600s (10 min): plenty for a CI image build+push. No renewal —
# the JWT is single-use, and short TTL means a leaked token expires before
# anyone can exfiltrate it.
# NOTE on the `vault write -` form: `bound_claims` is a map type. Passing it
# as a flag (`bound_claims='{"...":"..."}'`) makes the CLI treat the value
# as a string, and Vault rejects with `expected a map, got 'string'`. Piping
# JSON via stdin (`vault write -`) is the canonical way to send map fields.
vault write auth/jwt/role/harbor-robot-pusher - <<'EOF'
{
  "role_type": "jwt",
  "user_claim": "repository",
  "bound_audiences": ["https://github.com/Shion1305", "https://github.com/Shion1305Dev"],
  "bound_claims_type": "glob",
  "bound_claims": {
    "repository_owner": ["Shion1305", "Shion1305Dev"]
  },
  "token_policies": ["harbor-robot-pusher-reader"],
  "token_ttl": "600",
  "token_max_ttl": "600",
  "token_explicit_max_ttl": "600"
}
EOF
echo "✓ Created JWT role: harbor-robot-pusher"

echo ""
echo "=== Removing old broad policy ==="
vault policy delete eso-policy 2>/dev/null && echo "✓ Deleted old policy: eso-policy" || echo "ⓘ Policy eso-policy not found (already removed)"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Per-namespace roles created:"
echo "  eso-langfuse    → SA eso/langfuse        → secret/data/shared/langfuse"
echo "  eso-openwebui   → SA eso/openwebui       → secret/data/shared/openwebui"
echo "  eso-outline     → SA eso/outline         → secret/data/shared/outline"
echo "  eso-keycloak    → SA eso/keycloak        → secret/data/shared/keycloak"
echo "  eso-atc         → SA eso/atc             → atc/data/*"
echo "  eso-lumos-bot   → SA eso/lumos-bot       → lumos-bot/data/*"
echo "  eso-freqtrade   → SA eso/freqtrade       → freqtrade/data/*"
echo "  eso-claude-code → SA eso/claude-code     → claude-code/data/*"
echo "  eso-scalable-llm→ SA eso/scalable-llm    → scalable-llm/data/*"
echo "  eso-cert-manager→ SA eso/cert-manager    → system/data/cert-manager"
echo "  eso-zot         → SA eso/zot             → zot/data/*"
echo "  eso-harbor      → SA eso/harbor          → harbor/data/*"
echo "  eso-nc-press-chotatsu → SA eso/nc-press-chotatsu → nc-press-chotatsu/data/*"
echo "  eso-fde-knowledge-engine → SA eso/fde-knowledge-engine → fde-knowledge-engine/data/*"
echo "  eso-github-app  → SA external-secrets/external-secrets → github-app-shared/data/*"
echo "  eso-cloudflare-grafana → SA eso/monitoring     → cloudflare-grafana/data/*"
echo "  eso-cluster-puller → SA external-secrets/external-secrets → zot/data/cluster-puller"
echo "  eso-harbor-pull → SA external-secrets/external-secrets → harbor/data/robot-puller"
echo ""
echo "GitHub Actions JWT roles:"
echo "  harbor-robot-pusher → repository_owner ∈ {Shion1305, Shion1305Dev} → harbor/data/robot-pusher"
