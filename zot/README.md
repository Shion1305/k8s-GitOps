# zot OCI Registry

Self-hosted [zot](https://zotregistry.dev) registry serving images at:

- `registry.shion1305.com` — public, reachable from the internet
- `registry.i.shion1305.com` — internal, reachable only over WireGuard

The full architecture and rollout plan lives in
[`docs/zot-registry-deployment-plan.md`](../docs/zot-registry-deployment-plan.md).
This README covers operator-facing day-2 details.

## Architecture summary

zot runs as a single replica with a Longhorn-backed PVC. It is **bearer-only**:
every request to either hostname must carry `Authorization: Bearer <jwt>`,
where `<jwt>` is one of:

| Caller | Issuer | Audience |
|---|---|---|
| GitHub Actions push | `https://token.actions.githubusercontent.com` | `registry.shion1305.com` |
| Browser UI login | `https://keycloak.shion1305.com/realms/zot` | `zot-registry` |
| Cluster pull (kubelet) | `https://keycloak.shion1305.com/realms/zot` | `zot-registry` |
| Manual `docker pull` from a WireGuard host | `https://keycloak.shion1305.com/realms/zot` | `zot-registry` |

Anonymous pulls are NOT supported. zot's bearer dispatcher short-circuits to
401 when no Authorization header is present, even when `defaultPolicy`
permits read.

The Web UI's OIDC code-flow is run by **Envoy Gateway** (`SecurityPolicy.oidc`
→ `securitypolicy.yaml`), not by zot itself or any sidecar. Envoy stores the
session in encrypted cookies, refreshes the access token automatically, and
forwards it upstream as `Authorization: Bearer <kc_at>` so zot's
`http.auth.bearer.oidc[]` validates it.

GitHub Actions tokens go through a separate HTTPRoute that does NOT have a
SecurityPolicy attached, so docker push retains its native bearer challenge
flow with zot.

## Granting a human user push rights

1. Sign in once to `https://registry.shion1305.com/` so Keycloak's first-broker
   login from realm `user` provisions the local account in realm `zot`.
2. In the Keycloak admin UI, switch to realm `zot` → Users → select the user.
3. Open Groups → Join → add one of:
   - `zot-admin` — full read/write/delete on every repository
   - `pusher-shion1305` — push to `shion1305/**`
   - `pusher-shion1305dev` — push to `shion1305dev/**`
4. Have the user log out and back in to refresh the token claims.

## Onboarding a namespace to cluster pull

> Available after the second-PR `zot-pull/` rollout lands.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <ns>
  labels:
    zot-pull/enabled: "true"
---
spec:
  imagePullSecrets:
    - name: zot-pull
```

A `ClusterExternalSecret` fans out a `dockerconfigjson` Secret named `zot-pull`
into every labelled namespace, refreshed every 15 minutes against the
`cluster-puller` Keycloak service-account client.

## Manual `docker login` from a WireGuard host

```bash
TOKEN=$(curl -s -X POST \
  https://keycloak.shion1305.com/realms/zot/protocol/openid-connect/token \
  -d grant_type=client_credentials \
  -d client_id=cluster-puller \
  -d client_secret="$CLIENT_SECRET" \
  | jq -r .access_token)

docker login registry.i.shion1305.com -u oidc -p "$TOKEN"
docker pull registry.i.shion1305.com/shion1305/demo:latest
```

The username is ignored by zot; pass any non-empty string. `$CLIENT_SECRET`
comes from `vault kv get zot/cluster-puller`.

## Realm recreation

`KeycloakRealmImport` is one-shot. To apply a YAML change to
`keycloak-operator/zot-realm.yaml`:

```bash
kubectl delete keycloakrealmimport zot -n keycloak
# admin UI: realm `zot` → Realm Settings → Action → Delete
```

ArgoCD recreates the CR and the operator reimports. Then:

1. Retrieve generated client secrets from the admin UI (`zot-ui`,
   `cluster-puller`).
2. Write them back to Vault:
   ```bash
   vault kv put zot/keycloak-client clientsecret=<zot-ui-secret>
   vault kv put zot/cluster-puller \
     client_id=cluster-puller \
     client_secret=<cluster-puller-secret>
   ```
3. Re-add users to their groups (federated-identity links are dropped on
   recreate).

## Troubleshooting

### 401 on `docker push` from GitHub Actions
- Verify the GHA workflow requests an OIDC token with `audience: registry.shion1305.com`.
- Decode the token: `echo $TOKEN | cut -d. -f2 | base64 -d | jq` — confirm
  `iss == https://token.actions.githubusercontent.com` and `aud` includes
  `registry.shion1305.com`.
- Confirm `repository_owner` is `Shion1305` or `Shion1305Dev`; CEL validation
  rejects everything else.

### 401 on browser UI
- Check `kubectl logs -n envoy-gateway-system -l app.kubernetes.io/name=envoy`
  for OIDC discovery errors.
- Confirm the `zot-ui-oidc-credentials` Secret exists in the `zot` namespace
  and contains non-empty `client-id` and `client-secret` keys.
- The Keycloak `oauth2-proxy` client (post-rename: `zot-ui`) must list both
  `https://registry.shion1305.com/oauth2/callback` and
  `https://registry.i.shion1305.com/oauth2/callback` in `redirectUris`.

### 401 on `docker pull` from a kubelet
- `kubectl get secret zot-pull -n <ns>` — must exist and be type
  `kubernetes.io/dockerconfigjson`.
- Decode: `kubectl get secret zot-pull -n <ns> -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq`
  — the `auth` field should decode to `oidc:<jwt>`. Decode the JWT and verify
  `aud` includes `zot-registry` and `groups` contains the appropriate pusher
  group.

### 403 on push or pull (authenticated but unauthorized)
- The token is valid but doesn't carry the right `groups` claim. For browser
  users, re-check group membership in Keycloak. For GitHub Actions, the CEL
  expression in `values.yaml` controls group assignment based on
  `repository_owner`.

### Inspecting zot config
```bash
kubectl exec -n zot zot-0 -- cat /etc/zot/config.json | jq
```
