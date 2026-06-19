# Cluster Networking & Ingress

This document describes how external and internal HTTP traffic enters the
cluster and how applications publish themselves on the network.

## TL;DR

- **Canonical**: Envoy Gateway (Gateway API). All HTTP traffic enters
  through the Gateway; all apps publish via `HTTPRoute`.

## Topology

```
Internet ──────► 141.147.189.36 (instance-k8s-proxy)
                        │
                        ▼
                 envoy-gateway-system / Gateway "external"
                        │
                        ├── listener "https"           hostname: *.shion1305.com
                        │      cert: wildcard-shion1305-com-tls
                        │
                        └── listener "https-legacy-k"  hostname: *.k.shion1305.com
                               cert: wildcard-k-shion1305-com-tls
                               (serves only 301-redirect HTTPRoutes —
                                deprecated, will be retired)

WireGuard ─────► 10.130.5.21
                        │
                        ▼
                 envoy-gateway-system / Gateway "internal"
                        │
                        └── listener "https"           hostname: *.i.shion1305.com
                               cert: wildcard-i-shion1305-com-tls
```

Both Gateways are reconciled by the `envoy-default` `GatewayClass`
(see `envoy-gateway/gatewayclass.yaml`). Listener TLS certificates are
issued by cert-manager via Let's Encrypt DNS-01 (Cloudflare); see
`envoy-gateway/certificates.yaml`.

## Hostname conventions

| Audience | Hostname pattern | Listener | Example |
|---|---|---|---|
| Public Internet | `*.shion1305.com` | external / `https` | `argocd.shion1305.com` |
| Public legacy (DEPRECATED) | `*.k.shion1305.com` | external / `https-legacy-k` | redirect → `*.shion1305.com` |
| WireGuard / internal | `*.i.shion1305.com` | internal / `https` | `longhorn.i.shion1305.com` |

The `*.k.shion1305.com` space survives only as 301-redirect HTTPRoutes on
the `https-legacy-k` listener.
Server-to-server clients (CLIs, OAuth callbacks, JWT issuers) **must**
target the apex hostname directly — most clients do not follow redirects
on POSTs and OIDC discovery returns the canonical issuer URL anyway.

## Publishing an app

Add an `HTTPRoute` in the app's namespace that attaches to the
appropriate Gateway listener via `parentRefs`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app>-external
  namespace: <app-ns>
spec:
  parentRefs:
    - name: external                  # or "internal"
      namespace: envoy-gateway-system
      sectionName: https              # listener name
  hostnames:
    - <app>.shion1305.com             # or <app>.i.shion1305.com
  rules:
    - backendRefs:
        - name: <service-name>
          port: <port>
```

Cross-namespace `parentRefs` work because each Gateway listener has
`allowedRoutes.namespaces.from: All`. To allow the Gateway's namespace
to reach a backend `Service` in your app's namespace, also add a
`ReferenceGrant`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: ReferenceGrant
metadata:
  name: allow-envoy-gateway
  namespace: <app-ns>
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: envoy-gateway-system
  to:
    - group: ""
      kind: Service
```

The `ReferenceGrant` is technically redundant for the
`HTTPRoute → parentRef Gateway` cross-namespace attachment (which is
permitted by `allowedRoutes`), and same-namespace `backendRefs` don't
need a grant either. The pattern is included for consistency with
existing apps and to future-proof against backend `Service`s living in a
different namespace.

## TLS

- Listener certs are wildcard certificates owned by the `envoy-gateway-
  system` namespace. Apps do **not** manage their own TLS Secrets when
  using Gateway API.
- TLS terminates at the Gateway. Backends are reached over plain HTTP
  unless a `BackendTLSPolicy` is attached.
- For apps that previously used `backend-protocol: HTTPS` annotations
  (e.g., argocd serving its own self-signed cert on :443), prefer
  switching the upstream to plain HTTP (`server.insecure=true` in
  argocd's case) rather than introducing `BackendTLSPolicy`. Internal
  pod-to-pod traffic is policed by Cilium.

## OIDC, redirects, and policy attachment

Envoy Gateway ships extension APIs in `gateway.envoyproxy.io/v1alpha1`:

- `SecurityPolicy` — OIDC / JWT / authn enforcement, attached to one or
  more `HTTPRoute`s. Used by the zot UI; see
  `zot/securitypolicy.yaml`.
- `BackendTrafficPolicy` — connection / retry / timeout / circuit-
  breaker tuning per backend.
- `EnvoyExtensionPolicy` — Lua / external-processing filters. Used by
  the zot SPA mgmt rewrite.

301 redirects use `HTTPRoute.rules.filters.requestRedirect`. The
Gateway API CEL validator restricts `statusCode` to 301 or 302; 308 is
rejected.

## Internal-only access

The internal Gateway sits on `10.130.5.21` and is reachable only from
the WireGuard CIDR (the LAN-side L4 control). There is no
SecurityPolicy / IP-allowlist on the internal Gateway today; defense in
depth at L7 may be added later.

## Home-resident gateway (in-cluster split-horizon)

The canonical Envoy data plane is a single proxy pinned to `instance-k8s-proxy`
(the OCI node) with `hostNetwork`, owning both `141.147.189.36` and
`10.130.5.21`. That is correct for genuinely external traffic, but it means an
**in-cluster** client on a home node that talks to a `*.shion1305.com` /
`*.i.shion1305.com` host hairpins **home → OCI → home**: the request leaves to
the OCI gateway and the gateway proxies straight back to a backend that usually
runs on a home node. For large transfers (e.g. a GARM runner pushing a
multi-arch image to Harbor) this wastes the home uplink / WireGuard mesh badly.

The fix is a **second, home-resident Envoy fleet** plus **split-horizon DNS**:

- `GatewayClass envoy-home` → `EnvoyProxy home` runs Envoy on the amd64 home
  nodes (`shion-ubuntu-2505` / `shion-ubuntu-2605`), **not** hostNetwork,
  reached via an in-cluster ClusterIP (`envoy-gateway/envoyproxy-home.yaml`).
- `Gateway home` terminates `*.shion1305.com` and `*.i.shion1305.com` on `:443`
  by SNI, reusing the **same wildcard certificates** as the OCI gateway
  (`envoy-gateway/gateway-home.yaml`).
- `Service home-ingress` is a stable-named ClusterIP in front of that fleet
  (`envoy-gateway/service-home.yaml`); the EG-provisioned Service has a hashed
  name, so this hand-authored one is what CoreDNS targets.
- CoreDNS rewrites the opted-in hostnames to that Service
  (`kube-system-manual-config/coredns-configmap.yaml`), so a pod's request
  terminates on a home node and reaches the backend over the home network only.

An app opts in by (a) adding the `home` Gateway to its HTTPRoute `parentRefs`
and (b) adding a CoreDNS `rewrite` line for its hostname. Today only Harbor is
wired (`harbor/httproute-external.yaml`, `harbor/httproute-internal.yaml`). The
two opt-ins must stay in lockstep — a hostname rewritten to `home-ingress`
without a matching route on the `home` Gateway returns 404.

Scope and limits (current = "Phase 1"):

- **Pods only.** The CoreDNS rewrite governs pod DNS. **kubelet image pulls use
  the node resolver, not CoreDNS**, so in-cluster *pulls* still reach the OCI
  gateway; redirecting those needs a per-node `/etc/hosts`/NodeHosts step (a
  later phase). The immediate win is pod-originated traffic — notably runner
  `crane push`.
- **No same-host pinning yet.** `home-ingress` is a plain ClusterIP, so a pod
  may terminate on either home node (one cheap home-LAN hop) rather than its
  own. A later phase can switch the fleet to a DaemonSet and add
  `internalTrafficPolicy: Local` to pin termination to the client's node.
- **External clients are unchanged.** Public DNS still points at
  `141.147.189.36` / `10.130.5.21`; only in-cluster resolution is overridden.

`kube-system-manual-config/coredns-configmap.yaml` is **not** managed by ArgoCD
— apply it by hand and roll CoreDNS:

```bash
kubectl apply -f kube-system-manual-config/coredns-configmap.yaml
kubectl rollout restart -n kube-system deployment/coredns
```

## Migration status

| Phase | Status | Notes |
|---|---|---|
| Envoy Gateway deployed | ✅ done | `envoy-gateway-system` namespace |
| Wildcard certificates issued | ✅ done | apex, `*.i`, `*.k` (legacy) |
| Per-app HTTPRoute migration | ✅ done | All currently-deployed apps |
| 301-redirects on `*.k` | ✅ done | argocd, langfuse, openwebui, github-readme-stats, ynufes-cf-grafana, keycloak, vault |
| DNS repoint of `*.k` to Envoy | 🟡 in progress | Per-record cutover; tracked out-of-band |
| `*.k` listener + cert removal | ⏳ pending | Once all redirects unused |

## Anti-patterns (do not do this)

- **Do not add new `Ingress` resources.** Use `HTTPRoute`. Renovate /
  CI does not currently enforce this; reviewers should reject new
  `Ingress` manifests in PRs.
- **Do not write to the `https-legacy-k` listener** for new traffic.
  It only serves 301-redirect HTTPRoutes; new app routes go on the
  regular `https` listener at the apex hostname.
- **Do not put per-app TLS Secrets in the app namespace** when using
  Gateway API. The Gateway listener owns the cert.
- **Do not bypass the Gateway with a NodePort** unless explicitly
  documented (e.g., the cloudflare-grafana NodePort is a temporary
  ServiceMonitor scrape target, slated for removal once the HTTPRoute
  is verified).

## See also

- `envoy-gateway/` — Gateway / GatewayClass / Certificate manifests
- `keycloak-operator/httproute-external.yaml` + `httproute-legacy-redirect.yaml`
  — canonical example of the apex + redirect pattern
- `zot/securitypolicy.yaml` — example of OIDC `SecurityPolicy` attachment
