# ATC (Automated Trading System)

## Components

### PostgreSQL
- Managed by Zalando Postgres Operator in `postgres-operator-deployment` namespace
- Database: `atc`, User: `atcuser`
- Connection secret: `atc-database-secret` (key: `ATC_DATABASE_URL`)
- External access (via WireGuard): `atc.i.shion1305.com:5432`, exposed through the
  internal Envoy Gateway's `tls-passthrough` listener (SNI-routed). Connect with
  `sslmode=require` — Spilo presents its own cert; Envoy does not terminate TLS.

### Grafana
- Standalone instance at `https://atc-grafana.i.shion1305.com` (envoy-gateway internal listener)
- Datasources (auto-provisioned via initContainer):
  - **atc-postgres**: Parsed from `atc-database-secret`
  - **atc-prometheus**: Push-based Prometheus at `http://prometheus.atc.svc.cluster.local:9090`
- Default credentials: `admin` / `admin` (change on first login)

### Prometheus
- Push-only instance at `https://atc-prom.i.shion1305.com` (envoy-gateway internal listener)
- Remote write endpoint: `/api/v1/write`
- Storage: 100Gi on `longhorn-hdd`, size-based retention (85GB)
- In-cluster: `http://prometheus.atc.svc.cluster.local:9090`

### Other Services
- **ws-stream**: WebSocket stream processor
- **postgres-mcp**: MCP connector for database access
