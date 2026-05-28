# clearnet-website-monitoring

Deploys the `provider_monitor` exporter from
[`Shion1305/ylab-clearnet-research`](https://github.com/Shion1305/ylab-clearnet-research).
The exporter probes a list of domains across registrar / NS / host /
certificate tiers and exposes Prometheus metrics so registrar-led takedown
response can be tracked over time.

The container image is built by that repo's
`.github/workflows/harbor-publish.yaml` and pushed to
`harbor.shion1305.com/shion1305/provider-monitor`. Kubelet pulls from
`harbor.i.shion1305.com/shion1305/provider-monitor:latest` and Kyverno's
`harbor-pull-injection` ClusterPolicy adds the imagePullSecret on Pod
admission.

## Domains list

The list of domains the exporter probes is **not stored in this public
repo** — it lives in Vault under the `clearnet-website-monitoring/` KV v2
mount and is materialized into the `clearnet-website-monitoring-domains`
Kubernetes Secret by External Secrets Operator (`external-secret.yaml`).
The Secret is mounted into the exporter Pod at `/data/domains.txt`;
`provider_monitor` re-reads the file at the start of every probe round, so
updates take effect on the next round (no Pod restart needed; allow ~5 min
for ESO refresh plus the exporter's `PROVIDER_MONITOR_INTERVAL`).

### One-time setup

```sh
# 1. Enable a dedicated KV v2 mount in Vault
vault secrets enable -path=clearnet-website-monitoring kv-v2

# 2. Apply the Vault policy + Kubernetes auth role
bash vault/scripts/setup-eso-policies.sh

# 3. Seed the initial domains list (see "Updating the list" below)
```

### Updating the list

```sh
# Prepare the file locally
cat >/tmp/domains.txt <<'EOF'
example.com
another-domain.example
EOF

# Push to Vault — overwrites the existing value
vault kv put clearnet-website-monitoring/domains \
  domains.txt=@/tmp/domains.txt

# Optional: verify the materialized Secret in-cluster (re-syncs within 5m)
kubectl get secret clearnet-website-monitoring-domains \
  -n clearnet-website-monitoring \
  -o jsonpath='{.data.domains\.txt}' | base64 -d
```

Lines starting with `#` and blank lines are ignored by the exporter.

## State persistence

The exporter writes baselines and round snapshots under
`/app/out/provider_monitor`, backed by a 5 Gi Longhorn PVC
(`clearnet-website-monitoring-data`). Without persistence the first round
after a Pod restart re-baselines every domain and the `*_changed` diff
metrics report spurious zeros until enough history accumulates.

## Dashboards

A `GrafanaDashboard` CR (`grafana-dashboard.yaml`) wires the "Clearnet
Website Monitoring" dashboard into the main Grafana instance under the
"Clearnet Website Monitoring" folder. Available at
<https://o11y.shion1305.com/grafana>.
