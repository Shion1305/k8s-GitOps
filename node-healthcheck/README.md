# Node Health Check

Node-specific health check CronJobs that ping healthcheck.io endpoints every minute to monitor node availability.

## Features

- Separate CronJob for each node (instance-2024-1, raspi-cm4, shion-ubuntu-2505)
- Runs every minute on specific nodes using nodeAffinity
- Works even on nodes with scheduling disabled (tolerates all taints)
- Health check URLs stored in Kubernetes secret

## Prerequisites

You must manually create the secret containing health check URLs:

```bash
kubectl create namespace node-healthcheck

kubectl create secret generic node-healthcheck-urls \
  --namespace=node-healthcheck \
  --from-literal=instance-2024-1-url='https://hc-ping.com/<uuid-1>' \
  --from-literal=raspi-cm4-url='https://hc-ping.com/<uuid-2>' \
  --from-literal=shion-ubuntu-2505-url='https://hc-ping.com/<uuid-3>'
```

Replace `<uuid-1>`, `<uuid-2>`, and `<uuid-3>` with your actual healthcheck.io UUIDs.

## Verification

```bash
# Check CronJobs are created
kubectl get cronjob -n node-healthcheck

# View recent job executions
kubectl get jobs -n node-healthcheck

# Check pods (including which node they ran on)
kubectl get pods -n node-healthcheck -o wide

# View logs from a specific job
kubectl logs -n node-healthcheck <pod-name>
```

## How It Works

Each CronJob:

1. Uses `nodeAffinity` to pin to a specific node via `kubernetes.io/hostname`
2. Uses `tolerations: operator: Exists` to tolerate all taints (including scheduling disabled)
3. Reads its health check URL from the `node-healthcheck-urls` secret
4. Executes `curl -fsS` to ping the health check endpoint

This ensures health checks run on all nodes, even those that are cordoned or have scheduling disabled.
