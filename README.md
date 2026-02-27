# k8s-GitOps

This repository implements a comprehensive GitOps workflow for Kubernetes using ArgoCD, managing multiple applications and infrastructure components.

## Applications

### Data & Analytics

- **Airbyte** - Open-source data integration platform with metrics exporter
- **Vald** - Scalable vector search engine
- **PostgreSQL** - Database with Crunchy PostgreSQL Operator

### Identity & Access Management

- **Keycloak** - Identity and access management solution

### Monitoring & Observability

- **Grafana** - Monitoring dashboards and visualization
- **Prometheus** - Metrics collection and alerting
- **Node Exporter** - System metrics collection

### Infrastructure

- **Zot** - OCI container registry
- **Local Storage** - Local path provisioner for persistent volumes
- **NGINX Ingress** - Ingress controller with SSL support

### Development & Testing

- **Guestbook** - Sample application for testing
- **Network Stress Test** - Network performance testing tools

## Repository Structure

- `apps/` - ArgoCD Application manifests for all services
- `argocd/` - ArgoCD configuration and ingress
- `storage/` - Local storage provisioning, policies, and persistent volumes
- `ingress/` - NGINX ingress controller configuration
- `charts/` - Custom Helm charts
- Individual service directories with values.yaml and configuration files

## Setup Scripts

- `manage-postgres.sh` - PostgreSQL management utilities
- `setup-pv-dirs.sh` - Persistent volume directory setup
- `setup-storage.sh` - Storage configuration setup
