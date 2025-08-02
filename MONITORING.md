# Monitoring Stack Deployment

This repository now includes a comprehensive monitoring stack with node-exporter, Prometheus, and Grafana deployed via ArgoCD.

## Components

### Node Exporter

- **Namespace**: `node-exporter`
- **Purpose**: Collects hardware and OS metrics from Kubernetes nodes
- **Deployment**: Helm chart from prometheus-community
- **Configuration**: Deployed only on available node `shion-ubuntu-2505` (ignoring cordoned nodes)
- **Service Discovery**: Uses ServiceMonitor for Prometheus integration

### Grafana + Prometheus Stack

- **Namespace**: `grafana`
- **Purpose**: Monitoring, alerting, and visualization platform
- **Components Included**:
  - Grafana (NodePort 30080)
  - Prometheus (with 30-day retention and 20GB storage)
  - AlertManager (with 5GB storage)
  - Kube State Metrics

## ArgoCD Applications

1. **node-exporter-app.yaml**: Deploys node-exporter to collect node metrics
2. **grafana-app.yaml**: Deploys kube-prometheus-stack with Grafana and Prometheus

## Access Information

### Grafana

- **URL**: `http://<node-ip>:30080`
- **Username**: `admin`
- **Password**: `admin123` (change in production!)

### Pre-configured Dashboards

- Kubernetes Cluster Monitoring (Dashboard ID: 7249)
- Node Exporter Full (Dashboard ID: 1860)
- Node Exporter Server Metrics (Dashboard ID: 405)

## Features

### Node Metrics

- CPU usage, load average, memory utilization
- Disk I/O, network traffic, filesystem usage
- Hardware temperature, power metrics (if available)
- All metrics are filterable by node labels

### Service Discovery

- Prometheus automatically discovers ServiceMonitors across all namespaces
- Node-exporter metrics are automatically scraped every 30 seconds
- Proper labeling for node identification and filtering

### Storage

- Prometheus: 20GB persistent volume with 30-day retention
- Grafana: 10GB persistent volume for dashboards and configuration
- AlertManager: 5GB persistent volume for alert state persistence

## Deployment via ArgoCD

Both applications are configured with:

- Automated sync enabled
- Self-healing enabled
- Automatic namespace creation
- Helm value files from this repository

## Monitoring Node Labels

The setup includes proper node labeling to filter metrics by:

- `instance`: Node instance identifier
- `node`: Kubernetes node name
- `nodename`: Extracted from pod metadata

## Security Considerations

⚠️ **Production Notes**:

- Change the default Grafana admin password
- Consider using HTTPS with proper certificates
- Implement proper RBAC for Grafana users
- Use secrets management for sensitive configuration

## Troubleshooting

### If node-exporter is not showing metrics

1. Check if the node-exporter pod is running: `kubectl get pods -n node-exporter`
2. Verify ServiceMonitor: `kubectl get servicemonitor -n node-exporter`
3. Check Prometheus targets: Access Prometheus UI and verify targets

### If Grafana dashboards are not loading

1. Verify datasource configuration in Grafana
2. Check Prometheus connectivity from Grafana namespace
3. Ensure dashboard JSON files are properly loaded
