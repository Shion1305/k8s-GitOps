# Network Policies — Cross-Namespace Isolation (Cilium + Kyverno)

Cluster-wide cross-namespace isolation. Cilium (`enable-policy: default`)
enforces standard and Cilium network policies together as a union of allows.

## Model

- **Ingress is default-denied per namespace; egress is left open.** A pod accepts
  a cross-namespace connection only when an allow exists; egress to the internet,
  DNS and the API server are unaffected.
- `cross-ns-isolation-generator.yaml` (Kyverno `ClusterPolicy`) generates a
  default-deny-ingress NetworkPolicy that allows same-namespace ingress into every
  non-system namespace, **including ones created later** (new apps). A standard
  `networking.k8s.io` NetworkPolicy is used so Kyverno needs no extra RBAC.
- `allow-from-infra.yaml` adds the universal cross-namespace ingress allows:
  `host`/`remote-node` (kubelet probes), `kube-apiserver` (webhooks), `health`,
  the `envoy-gateway-system` namespace (ingress proxy), and the `grafana`
  namespace (Prometheus scrape + operator).
- **East-west (app-to-app) allows live in each receiving app's own directory**, as
  a `CiliumNetworkPolicy` alongside that app's other manifests.

### Excluded namespaces

The generator excludes `kube-system`, `kube-node-lease`, `kube-public` (CoreDNS
serves DNS to every namespace) and `kyverno` (decoupled from its own engine).
To exclude more, add names to the generator's `exclude.any[].resources.names`.

## East-west allows

| Receiver | Allowed source(s) | Port | File |
|---|---|---|---|
| shared Postgres (`postgres-operator-deployment`) | adminer, atc, harbor, keycloak, langfuse, mlflow, nc-press-chotatsu, openwebui, postgres-operator | 5432 | `postgres-shared/networkpolicy.yaml` |
| shared Postgres | postgres-operator (Patroni) | 8008 | `postgres-shared/networkpolicy.yaml` |
| `vault` | external-secrets | 8200 | `vault/networkpolicy.yaml` |
| `atc` (`app=postgres-mcp`) | openwebui | 8000 | `atc/network-policy-openwebui-to-mcp.yaml` |
| `monitoring` (`app=cloudflare-grafana`) | world (external) | 3000 | `cloudflare-exporter/networkpolicy.yaml` |
| `grafana` (Prometheus) | monitoring (cloudflare-grafana datasource) | 9090 | `grafana/networkpolicy.yaml` |

To allow a new cross-namespace path, add a `CiliumNetworkPolicy` (additive,
`enableDefaultDeny: false`) to the receiving app's directory.

## Rollout

`root-app` auto-syncs `apps/`, so merging `apps/network-policies-app.yaml` applies
the generator with `generateExisting: true` and default-denies ingress across all
non-excluded namespaces in one sync.

To stage, enable the deny on a pilot namespace first so misses are observable —
scope the generator with `match.any[].resources.names: [<pilot-ns>]`, watch
`hubble observe -f --namespace <pilot-ns> --verdict DROPPED`, add any missing
source to the receiver's app directory, then widen. (Disabling the generator and
watching for drops does **not** work: with nothing denied, the DROPPED log is
empty regardless of coverage.)

```bash
hubble observe -f --verdict DROPPED                                   # legitimate drops?
kubectl get netpol -A -l network-policies/purpose=cross-ns-isolation  # one per namespace
```

## Rollback

Delete the `cross-ns-isolation` ClusterPolicy; `synchronize: true` removes every
generated NetworkPolicy and all namespaces return to default-allow. Verify (Kyverno
must be healthy to garbage-collect):

```bash
kubectl get netpol -A -l network-policies/purpose=cross-ns-isolation  # expect: none
kubectl delete netpol -A -l network-policies/purpose=cross-ns-isolation  # force if any remain
```

To exempt one namespace, add its name to the generator's `exclude` list.
