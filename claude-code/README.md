# claude-code — Claude Code OTLP governance receiver

OpenTelemetry Collector that receives Claude Code telemetry over OTLP and
persists it for governance. Published on the **internal** Gateway at
`cc.i.shion1305.com` (WireGuard-only), protected by a bearer token.

## Architecture

```
Claude Code ──OTLP/HTTP, Bearer token──► cc.i.shion1305.com
                                            │ Envoy internal Gateway (TLS terminate)
                                            ▼
                          OTel Collector (claude-code-opentelemetry-collector)
                          bearertokenauth validates Authorization header
                             │ logs                      │ metrics
                             ▼                            ▼
                  Loki (loki:3100, 90d retention)   Prometheus (ServiceMonitor → :8889)
                             │
                             ▼
                  Grafana Explore (Loki datasource)
```

- **Receiver:** `apps/claude-code-app.yaml` (chart `opentelemetry-collector`,
  contrib image — the core image lacks `bearertokenauth`). Config in
  `values.yaml`.
- **Store:** `apps/loki-app.yaml` (chart `loki`, SingleBinary, filesystem on
  Longhorn, 90-day retention). Both run in the `claude-code` namespace.
- Only **OTLP/HTTP (4318)** is exposed (`HTTPRoute` is HTTP-only; gRPC/4317
  would need a `GRPCRoute`). Use the `http/protobuf` exporter.

## What is captured

Claude Code's OTel feature emits **events/logs** — `user_prompt`,
`tool_result`, `tool_decision`, `api_request`, `api_error` — and **metrics**
(token usage, cost, session count, active time, lines-of-code). It does **not**
emit full assistant responses; "conversation data" here means the prompt +
tool/API event stream. Prompt *content* is only included when the client sets
`OTEL_LOG_USER_PROMPTS=1` (off by default).

## Client configuration

Set these in the Claude Code environment (or `settings.json` `env`):

```sh
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=https://cc.i.shion1305.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>"   # vault kv get claude-code/otlp
export OTEL_LOG_USER_PROMPTS=1   # capture prompt content for governance
```

The endpoint is only reachable from the WireGuard network.

## Querying

Grafana → Explore → datasource **Loki**:

```logql
{service_name="claude-code"}
```

Filter by event, e.g. `{service_name="claude-code"} | event_name = "user_prompt"`.
Metrics are in Prometheus as `claude_code_*` (e.g. `claude_code_token_usage`).

## Secret / token management

The bearer token lives in Vault and is synced to the `claude-code-otlp-token`
Secret by External Secrets Operator (`external-secret.yaml`).

One-time setup (run out-of-band by an operator — never commit the token):

```sh
# Vault policy + role are added by vault/scripts/setup-eso-policies.sh
vault secrets enable -path=claude-code kv-v2
vault kv put claude-code/otlp token="$(openssl rand -hex 32)"
```

Rotating the token: `vault kv put claude-code/otlp token=<new>`, then restart the
collector Deployment (the `bearertokenauth` extension reads the token file at
startup), and update each client's `OTEL_EXPORTER_OTLP_HEADERS`.

## Notes

- Loki is single-replica/filesystem — sized for an append-only audit store at
  homelab volume, not HA. Promote to a dedicated namespace if logging later
  becomes shared infrastructure.
- No custom NetworkPolicy is needed: the cluster-wide `allow-from-infra`
  policies already permit Envoy Gateway → collector and Prometheus scrapes, and
  the Kyverno cross-namespace isolation generator allows same-namespace
  collector ↔ Loki traffic.
