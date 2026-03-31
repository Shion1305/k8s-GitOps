# Network Policies

This directory contains centralized NetworkPolicy configurations for cluster-wide namespace isolation.

## Structure

```
network-policies/
├── base/                           # Base NetworkPolicy templates
│   ├── default-deny-all.yaml      # Denies all traffic by default
│   ├── allow-same-namespace.yaml  # Allows intra-namespace traffic
│   ├── allow-dns.yaml             # Allows DNS queries
│   ├── allow-kube-api.yaml        # Allows Kubernetes API access
│   └── kustomization.yaml
├── namespaces/                     # Namespace-specific kustomizations
│   ├── adminer.yaml
│   ├── airbyte.yaml
│   ├── ...                         # One file per namespace
│   └── zot.yaml
├── kustomization.yaml              # Main kustomization (references all namespaces)
└── README.md
```

## Default Behavior

Each namespace listed in `namespaces/` will get these 4 NetworkPolicies:

1. **default-deny-all**: Blocks all ingress and egress traffic by default
2. **allow-same-namespace**: Permits traffic between pods in the same namespace
3. **allow-dns**: Allows DNS resolution via kube-system
4. **allow-kube-api**: Allows access to Kubernetes API server

## Usage

### Build manifests

```bash
kubectl kustomize network-policies/
```

### Apply policies (dry-run)

```bash
kubectl apply -k network-policies/ --dry-run=client
```

### Apply policies

```bash
kubectl apply -k network-policies/
```

### Verify

Check policies in a specific namespace:

```bash
kubectl get networkpolicies -n <namespace>
```

## Adding New Namespaces

1. Create a new file in `namespaces/` (e.g., `namespaces/my-namespace.yaml`):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: my-namespace

resources:
  - ../base
```

2. Add it to the main `kustomization.yaml`:

```yaml
resources:
  - namespaces/my-namespace.yaml
```

## Cross-Namespace Communication

By default, pods **cannot** communicate across namespaces. To allow specific cross-namespace traffic, create additional NetworkPolicies in the respective namespace directories.

### Existing Cross-Namespace Policies

These are preserved and work alongside the default policies:
- `librechat/network-policy-to-mcp.yaml` - librechat → atc/postgres-mcp:8000
- `openwebui/network-policy-to-mcp.yaml` - openwebui → atc/postgres-mcp:8000
- `atc/network-policy-mcp-to-postgres.yaml` - atc/postgres-mcp → postgres-operator-deployment:5432
- `gh-analysis/networkpolicy.yaml` - gh-analysis → privacy-focused-gateway/instance-k8s-proxy:8080
- `privacy-focused-gateway/networkpolicy.yaml` - specific job restrictions
- `macos-timemachine/networkpolicy.yaml` - ingress from 192.168.0.0/16

## Important Notes

- Multiple NetworkPolicies are additive (OR logic)
- Existing namespace-specific NetworkPolicies are NOT replaced
- To allow ingress from `ingress-nginx`, you need to add specific policies per namespace
- External traffic (internet) is blocked by default unless explicitly allowed
