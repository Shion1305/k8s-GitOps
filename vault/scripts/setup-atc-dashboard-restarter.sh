#!/usr/bin/env bash
# Provision the least-privilege GitHub Actions -> Vault -> Kubernetes path
# used to roll the ATC dashboard after publishing a new :latest image.
#
# Prerequisites:
#   - VAULT_ADDR points at the internal Vault endpoint
#   - VAULT_TOKEN is an admin token
#   - kubectl targets the production cluster with TokenReview and
#     service-account/group impersonation authority
#   - gh is authenticated as a crypto-auto-trading repository admin
set -euo pipefail

for required in gh jq kubectl python3 vault; do
  command -v "$required" >/dev/null 2>&1 || {
    printf 'required command not found: %s\n' "$required" >&2
    exit 69
  }
done
: "${VAULT_ADDR:?set VAULT_ADDR to the internal Vault endpoint}"
: "${VAULT_TOKEN:?set VAULT_TOKEN to an admin token}"

repo="Shion1305/crypto-auto-trading"
namespace="atc"
service_account="ci-dashboard-restarter"
deployment="atc-dashboard"
token_bound_secret="ci-dashboard-restarter-token-bound"
token_duration="${ATC_DASHBOARD_RESTART_TOKEN_DURATION:-8760h}"
[[ "$token_duration" =~ ^[1-9][0-9]*h$ ]] || {
  printf 'ATC_DASHBOARD_RESTART_TOKEN_DURATION must be a positive integer number of hours\n' >&2
  exit 64
}

vault token lookup >/dev/null
kubectl -n "$namespace" get serviceaccount "$service_account" >/dev/null

set +e
credential_probe="$(
  vault kv metadata get -format=json k8s/ci-dashboard-restarter 2>&1
)"
credential_probe_status=$?
set -e
if [[ "$credential_probe_status" -eq 0 ]]; then
  printf 'restarter credential already exists; refusing to create an overlapping token\n' >&2
  printf 'follow the revocation procedure in vault/README.md before provisioning again\n' >&2
  exit 73
fi
if [[ "$credential_probe" != "No value found at "* ]]; then
  printf 'could not prove the restarter credential is absent; refusing to mint a token\n' >&2
  exit 74
fi
unset credential_probe

bound_secret_probe="$(
  kubectl -n "$namespace" get secret "$token_bound_secret" \
    --ignore-not-found -o name
)"
[[ -z "$bound_secret_probe" ]] || {
  printf 'token revocation handle already exists; refusing to mint an overlapping token\n' >&2
  exit 73
}
unset bound_secret_probe

bound_secret_created=false
credential_written=false
cleanup() {
  cleanup_status=$?
  trap - EXIT
  unset restart_token token_claims token_review
  if [[ "$cleanup_status" -ne 0 && "$credential_written" == true ]]; then
    vault kv metadata delete k8s/ci-dashboard-restarter >/dev/null 2>&1 || {
      printf 'WARNING: failed to remove the incomplete Vault credential\n' >&2
    }
  fi
  if [[ "$cleanup_status" -ne 0 && "$bound_secret_created" == true ]]; then
    kubectl -n "$namespace" delete secret "$token_bound_secret" --wait=true \
      >/dev/null 2>&1 || {
      printf 'WARNING: failed to remove the token revocation handle\n' >&2
    }
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

kubectl -n "$namespace" create secret generic "$token_bound_secret" >/dev/null
bound_secret_created=true
bound_secret_uid="$(
  kubectl -n "$namespace" get secret "$token_bound_secret" \
    -o jsonpath='{.metadata.uid}'
)"

restart_token="$(kubectl -n "$namespace" create token "$service_account" \
  --bound-object-kind=Secret \
  --bound-object-name="$token_bound_secret" \
  --duration="$token_duration")"

token_claims="$(printf '%s' "$restart_token" | python3 -c '
import base64
import json
import sys

token = sys.stdin.read().strip()
parts = token.split(".")
if len(parts) != 3:
    raise SystemExit("TokenRequest did not return a JWT")
payload = parts[1] + "=" * (-len(parts[1]) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
print(json.dumps({
    "subject": claims.get("sub"),
    "issued_at": claims.get("iat"),
    "expires_at": claims.get("exp"),
    "bound_secret_name": claims.get("kubernetes.io", {}).get("secret", {}).get("name"),
    "bound_secret_uid": claims.get("kubernetes.io", {}).get("secret", {}).get("uid"),
}))
')"
token_subject="$(jq -er '.subject' <<<"$token_claims")"
issued_at="$(jq -er '.issued_at | select(type == "number")' <<<"$token_claims")"
expires_at="$(jq -er '.expires_at | select(type == "number")' <<<"$token_claims")"
token_bound_secret_name="$(jq -er '.bound_secret_name' <<<"$token_claims")"
token_bound_secret_uid="$(jq -er '.bound_secret_uid' <<<"$token_claims")"
actual_ttl_seconds=$((expires_at - issued_at))
expected_ttl_seconds=$((${token_duration%h} * 3600))
[[ "$token_subject" == "system:serviceaccount:$namespace:$service_account" \
  && "$token_bound_secret_name" == "$token_bound_secret" \
  && "$token_bound_secret_uid" == "$bound_secret_uid" \
  && "$actual_ttl_seconds" -ge $((expected_ttl_seconds - 60)) \
  && "$actual_ttl_seconds" -le $((expected_ttl_seconds + 60)) ]] || {
  printf 'TokenRequest subject or actual TTL did not match the requested credential\n' >&2
  exit 78
}

token_review="$(printf '%s' "$restart_token" | jq -Rs '{
  apiVersion: "authentication.k8s.io/v1",
  kind: "TokenReview",
  spec: {token: .}
}' | kubectl create --raw /apis/authentication.k8s.io/v1/tokenreviews -f -)"
[[ "$(jq -r '.status.authenticated' <<<"$token_review")" == "true" \
  && "$(jq -r '.status.user.username' <<<"$token_review")" == "$token_subject" ]] || {
  printf 'TokenRequest credential did not authenticate as the expected service account\n' >&2
  exit 78
}

impersonation=(--as="$token_subject")
while IFS= read -r group; do
  impersonation+=(--as-group="$group")
done < <(jq -r '.status.user.groups[]' <<<"$token_review")
rules_review="$(
  printf '%s' \
    '{"apiVersion":"authorization.k8s.io/v1","kind":"SelfSubjectRulesReview","spec":{"namespace":"atc"}}' \
    | kubectl "${impersonation[@]}" create \
      --raw /apis/authorization.k8s.io/v1/selfsubjectrulesreviews -f -
)"
jq -e '
  def normalized:
    {
      apiGroups: ((.apiGroups // []) | sort),
      resources: ((.resources // []) | sort),
      resourceNames: ((.resourceNames // []) | sort),
      verbs: ((.verbs // []) | sort)
    };
  (.status.incomplete == false)
  and (.status.evaluationError == null)
  and (([.status.resourceRules[] | normalized] | sort_by(.apiGroups, .resources)) ==
    ([
      {
        apiGroups: ["apps"],
        resources: ["deployments"],
        resourceNames: ["atc-dashboard"],
        verbs: ["get", "patch"]
      },
      {
        apiGroups: ["authentication.k8s.io"],
        resources: ["selfsubjectreviews"],
        resourceNames: [],
        verbs: ["create"]
      },
      {
        apiGroups: ["authorization.k8s.io"],
        resources: ["selfsubjectaccessreviews", "selfsubjectrulesreviews"],
        resourceNames: [],
        verbs: ["create"]
      }
    ] | sort_by(.apiGroups, .resources)))
  and (([.status.nonResourceRules[] | {
      nonResourceURLs: ((.nonResourceURLs // []) | sort),
      verbs: ((.verbs // []) | sort)
    }] | sort_by(.nonResourceURLs)) ==
    ([
      {
        nonResourceURLs: [
          "/.well-known/openid-configuration",
          "/.well-known/openid-configuration/",
          "/openid/v1/jwks",
          "/openid/v1/jwks/"
        ],
        verbs: ["get"]
      },
      {
        nonResourceURLs: [
          "/api",
          "/api/*",
          "/apis",
          "/apis/*",
          "/healthz",
          "/livez",
          "/openapi",
          "/openapi/*",
          "/readyz",
          "/version",
          "/version/"
        ],
        verbs: ["get"]
      },
      {
        nonResourceURLs: [
          "/healthz",
          "/livez",
          "/readyz",
          "/version",
          "/version/"
        ],
        verbs: ["get"]
      }
    ] | sort_by(.nonResourceURLs)))
' >/dev/null <<<"$rules_review" || {
  printf 'restarter RBAC exceeds get+patch on %s plus Kubernetes self-review/discovery\n' \
    "$deployment" >&2
  exit 78
}

vault policy write dashboard-restarter-token-reader - <<'EOF'
path "k8s/data/ci-dashboard-restarter" {
  capabilities = ["read"]
}
EOF

vault write auth/jwt/role/dashboard-restarter - <<'EOF'
{
  "role_type": "jwt",
  "user_claim": "repository",
  "bound_audiences": ["https://github.com/Shion1305"],
  "bound_claims_type": "string",
  "bound_claims": {
    "repository": "Shion1305/crypto-auto-trading",
    "ref": "refs/heads/main",
    "workflow_ref": "Shion1305/crypto-auto-trading/.github/workflows/docker-publish-dashboard.yml@refs/heads/main"
  },
  "token_policies": ["dashboard-restarter-token-reader"],
  "token_no_default_policy": true,
  "token_ttl": "600",
  "token_max_ttl": "600",
  "token_explicit_max_ttl": "600"
}
EOF

printf '%s' "$restart_token" \
  | vault kv put k8s/ci-dashboard-restarter \
    token=- bound_object_secret="$token_bound_secret" >/dev/null
credential_written=true
unset restart_token

gh variable set DASHBOARD_RESTART_ENABLED --body true --repo "$repo"

printf 'dashboard restarter provisioned: repo=%s service_account=%s/%s actual_token_ttl=%ss\n' \
  "$repo" "$namespace" "$service_account" "$actual_ttl_seconds"
