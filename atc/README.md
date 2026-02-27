# ATC (Automated Trading System)

## Components

### PostgreSQL
- Managed by Zalando Postgres Operator in `postgres-operator-deployment` namespace
- Database: `atc`, User: `atcuser`
- Connection secret: `atc-database-secret` (key: `ATC_DATABASE_URL`)

### Grafana
- Standalone instance at `https://atc-grafana.k.shion1305.com` (nginx-internal)
- Datasources (auto-provisioned via initContainer):
  - **atc-postgres**: Parsed from `atc-database-secret`
  - **atc-prometheus**: Push-based Prometheus at `http://prometheus.atc.svc.cluster.local:9090`
- Default credentials: `admin` / `admin` (change on first login)

### Prometheus
- Push-only instance at `https://atc-prom.k.shion1305.com` (nginx-internal)
- Remote write endpoint: `/api/v1/write`
- Storage: 100Gi on `longhorn-hdd`, size-based retention (85GB)
- In-cluster: `http://prometheus.atc.svc.cluster.local:9090`

### Other Services
- **ws-stream**: WebSocket stream processor
- **postgres-mcp**: MCP connector for database access
