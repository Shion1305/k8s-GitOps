# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a GitOps repository managing a Kubernetes cluster using ArgoCD. All applications are declaratively defined and automatically synced from this repository to the cluster.

## ArgoCD Application Pattern

All applications follow a consistent multi-source pattern defined in `apps/*.yaml`:

```yaml
spec:
  sources:
  - repoURL: <upstream-helm-chart-repo>
    chart: <chart-name>
    targetRevision: <version>
    helm:
      valueFiles:
      - $values/<app-dir>/values.yaml
  - repoURL: https://github.com/Shion1305/k8s-GitOps.git
    targetRevision: HEAD
    ref: values  # Reference for Helm values
  - repoURL: https://github.com/Shion1305/k8s-GitOps.git
    targetRevision: HEAD
    path: <app-dir>  # Additional manifests (ingress, secrets, etc.)
```

When modifying applications:

- Helm chart configurations go in `<app-name>/values.yaml`
- Additional Kubernetes manifests (Ingress, Secrets, Jobs) go in the app's directory
- Version updates are done by changing `targetRevision` in `apps/<app-name>-app.yaml`

## Key Commands

### ArgoCD Management

```bash
# View all applications
kubectl get applications -n argocd

# Force sync an application
kubectl patch application <app-name> -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Access ArgoCD UI
# URL: https://argocd.k.shion1305.com
```

### PostgreSQL Operations

Use the `./manage-postgres.sh` script for PostgreSQL cluster management:

```bash
./manage-postgres.sh list                    # List clusters
./manage-postgres.sh status <cluster-name>   # Check cluster status
./manage-postgres.sh connect <cluster-name>  # Get connection info
./manage-postgres.sh users <cluster-name>    # List users and credentials
./manage-postgres.sh scale <cluster> <n>     # Scale to n instances
./manage-postgres.sh backup <cluster>        # Trigger manual backup
```

PostgreSQL clusters are managed by Zalando Postgres Operator in the `postgres-clusters` namespace.

### Storage Setup

```bash
# Create storage directories on nodes
./setup-storage.sh

# Setup persistent volume directories for specific apps
./setup-pv-dirs.sh
```

### Monitoring Access

```bash
# Grafana: http://<node-ip>:30080
# Username: admin / Password: admin123

# Check Prometheus targets
kubectl port-forward -n grafana svc/kube-prometheus-stack-prometheus 9090:9090
```

## Secret Management Architecture

This cluster uses a layered secret management approach:

**HashiCorp Vault** → **External Secrets Operator (ESO)** → **Kubernetes Secrets**

### Vault Configuration

- Deployed in HA mode with 3 replicas (Raft storage)
- UI: <https://vault.k.shion1305.com>
- Mount path: `secret/` (KV v2)
- Stores centralized secrets in paths like `secret/shared/app`

### External Secrets Operator

- Reads from Vault using ClusterSecretStore (`vault-cluster`)
- Authenticates via Kubernetes service account (`external-secrets`)
- Uses ClusterExternalSecret to distribute secrets across namespaces
- Only namespaces labeled with `secrets-sync/enabled=true` receive secrets

### Adding Secrets to Applications

1. Store secret in Vault: `vault kv put secret/shared/<service-name> KEY=value`
2. Create ClusterExternalSecret in `external-secrets/` directory
3. Label target namespace: `kubectl label namespace <ns> secrets-sync/enabled=true`
4. ESO automatically creates Secret in labeled namespaces

## Identity & Authentication

### Keycloak Setup

- **Purpose**: Provides OIDC/SAML authentication and Docker Registry v2 auth
- **URL**: <https://keycloak.k.shion1305.com>
- **Admin credentials**: admin/admin123
- **Realms**:
  - `master`: Admin realm
  - `registry`: Docker registry authentication
- **GitHub Actions Integration**: Uses OIDC token exchange via `gha-exchanger` client

### Zot Registry

- OCI container registry with Keycloak authentication
- Auth URL: <https://keycloak.k.shion1305.com/realms/registry/protocol/docker-v2/auth>
- Integrated with GitHub Actions for CI/CD workflows

## Storage

### Longhorn (Distributed Storage)

- Provides replicated block storage across cluster nodes
- Manages persistent volumes with replication and snapshots
- Backup target configured in `longhorn/backup-target.yaml`
- StorageClass: `longhorn` (defined in `longhorn/storageclass.yaml`)

### Node-specific Storage

- Local storage provisioner for node-pinned workloads
- Setup scripts create directories in `/var/local-storage` on nodes
- Used by applications requiring specific node placement

## Monitoring Stack

Deployed via kube-prometheus-stack (Grafana + Prometheus):

**Components:**

- Grafana: Visualization and dashboards (namespace: `grafana`)
- Prometheus: Metrics collection with 30-day retention, 200Gi storage
- AlertManager: Alert routing and management (5Gi storage)
- Node Exporter: Hardware/OS metrics from cluster nodes
- Kube State Metrics: Kubernetes object metrics

**Pre-configured Dashboards:**

- Kubernetes Cluster Monitoring (ID: 7249)
- Node Exporter Full (ID: 1860)
- Node Exporter Server Metrics (ID: 405)

**Custom Exporters:**

- Cloudflare Exporter: Monitors Cloudflare metrics with custom Grafana dashboard
- Airbyte Metrics Exporter: Monitors Airbyte data pipeline health

Service discovery via ServiceMonitors - Prometheus automatically discovers and scrapes targets across all namespaces.

## Ingress Configuration

Two ingress classes are configured:

1. **nginx-ssl**: SSL-enabled ingress with TLS termination
   - Used by: ArgoCD, Grafana, Keycloak, Vault, Zot
   - Configuration: `ingress/nginx-ssl-controller.yaml`

2. Standard ingress for internal services

Example ingress pattern:

```yaml
spec:
  ingressClassName: nginx-ssl
  tls:
    - hosts:
        - app.k.shion1305.com
  rules:
    - host: app.k.shion1305.com
```

## Application Directory Structure

Each application directory typically contains:

- `values.yaml`: Helm chart overrides
- `kustomization.yaml`: Kustomize configuration for additional resources
- Additional manifests: ingress, secrets, jobs, custom resources
- `README.md`: Application-specific documentation (when present)

## Common Troubleshooting Patterns

### Application not syncing

```bash
# Check application status
kubectl get application <app-name> -n argocd -o yaml

# View sync status
kubectl describe application <app-name> -n argocd

# Force refresh
kubectl delete application <app-name> -n argocd
kubectl apply -f apps/<app-name>-app.yaml
```

### Secret synchronization issues

```bash
# Check ESO operator logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets

# Verify ClusterSecretStore connection to Vault
kubectl describe clustersecretstore vault-cluster

# Force secret refresh
kubectl annotate clusterexternalsecret <name> force-sync="$(date +%s)" --overwrite
```

### Storage issues

```bash
# Check Longhorn status
kubectl get nodes -n longhorn-system
kubectl get volumes -n longhorn-system

# View PV/PVC status
kubectl get pv,pvc --all-namespaces
```

## Important Notes

- All applications use automated sync with self-healing enabled
- ArgoCD automatically creates namespaces via `CreateNamespace=true` sync option
- Most applications use `ServerSideApply=true` for better conflict resolution
- Domain: All ingress resources use `*.k.shion1305.com` domain
- Node labels and taints affect workload scheduling - check node status when troubleshooting pod placement
