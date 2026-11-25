#!/usr/bin/env bash
# Run from an authenticated operator shell after local Google authorization.
set -euo pipefail
: "${VAULT_ADDR:?Set VAULT_ADDR to the authenticated Vault endpoint}"
config_dir="${1:?Usage: bootstrap-secrets.sh /path/to/local/calendar-sync}"
for name in config.yaml credentials.json token.json; do
  test -s "${config_dir}/${name}" || { echo "Missing ${name}" >&2; exit 1; }
done
jq -e '.refresh_token | type == "string" and length > 0' "${config_dir}/token.json" >/dev/null
# Check operator authentication without printing the token or its metadata.
vault token lookup -format=json >/dev/null
mounts=$(vault secrets list -format=json)
if ! jq -e 'has("calendar-sync/")' <<<"${mounts}" >/dev/null; then
  vault secrets enable -path=calendar-sync kv-v2
elif ! jq -e '."calendar-sync/" | .type == "kv" and .options.version == "2"' <<<"${mounts}" >/dev/null; then
  echo 'Existing calendar-sync mount is not KV v2; refusing to modify it' >&2
  exit 1
fi
vault kv put calendar-sync/google \
  "config.yaml=@${config_dir}/config.yaml" \
  "credentials.json=@${config_dir}/credentials.json" \
  "token.json=@${config_dir}/token.json" >/dev/null
vault policy write eso-calendar-sync - >/dev/null <<'POLICY'
path "calendar-sync/data/google" {
  capabilities = ["read"]
}
POLICY
vault write auth/kubernetes/role/eso-calendar-sync \
  bound_service_account_names=eso \
  bound_service_account_namespaces=calendar-sync \
  policies=eso-calendar-sync \
  ttl=1h >/dev/null
printf '%s\n' 'Stored Google configuration and configured the scoped ESO role.'
