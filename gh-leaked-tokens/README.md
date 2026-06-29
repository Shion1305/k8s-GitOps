# gh-leaked-tokens

Periodic re-validation of already-discovered leaked API tokens, exported to
Prometheus. This is the in-cluster deployment of the `recheck` command from
[`gh-base64token-investigate`](https://github.com/Shion1305/gh-base64token-investigate).

## What it does

A CronJob runs `cli.py recheck` every 15 minutes. For each token already in the
research DB it re-probes the provider's API, records any **valid → invalid**
transition (the moment a leaked token gets disabled) to Postgres history, and
**pushes** every result to a Pushgateway. A **dedicated long-term Prometheus**
scrapes the gateway, so the `gh_token_valid` gauge over successive runs becomes
the token-disablement time-series the report audit trail depends on.

## Why a Pushgateway

`recheck` is a short-lived batch job — Prometheus can't scrape a pod that has
already exited. The job pushes to an always-on Pushgateway (Deployment + PVC for
persistence across restarts) and Prometheus scrapes that instead. The
ServiceMonitor sets `honorLabels: true` so the per-token `job`/`instance` labels
the job pushes are not overwritten by the scrape.

## Why a dedicated long-term Prometheus (not the primary)

Token validity is an **audit trail we must keep for years**. The primary
kube-prometheus-stack is **size-capped** (`retentionSize` is its real retention
factor), so its high-churn cluster-wide metrics continuously evict the oldest
samples — and this audit data would be collateral damage.

So `prometheus.yaml` runs a **separate, tiny Prometheus** scoped to this
namespace with **time-based retention only (10y), no size cap**. The series
volume is minuscule (a few per token), so it costs almost nothing while never
evicting history.

Routing is controlled by a **generic, namespace-agnostic opt-out label**,
`monitoring-tier: dedicated`, on the ServiceMonitor:

1. The **primary** excludes any SM carrying it — its `serviceMonitorSelector` is
   `monitoring-tier NotIn [dedicated]` (`grafana/values.yaml`). (Bare-label
   selection alone wouldn't have worked: the primary previously used an empty
   `{}` selector that scrapes everything regardless of labels, so an explicit
   NotIn is what actually keeps it off.)
2. The **dedicated** instance includes it — `serviceMonitorSelector:
   monitoring-tier=dedicated`, scoped to this namespace via its
   `serviceMonitorNamespaceSelector` so it doesn't grab another team's
   dedicated SM elsewhere.

The win: any future workload that needs its own retention just labels its
ServiceMonitor `monitoring-tier: dedicated` and points a dedicated instance at
it — **no edit to the primary is ever needed again** (vs. hard-coding each
namespace into a `NotIn` list).

Postgres `validation_checks` (append-only) remains the independent
source-of-truth; this Prometheus is the queryable long-term *view* of it. Even
if the Prometheus PVC were lost, the audit record in Postgres is intact.

Grafana reads it via a dedicated datasource (`uid: gh-leaked-tokens`, defined in
`grafana/datasource-gh-leaked-tokens.yaml`).

## Components

| File | Purpose |
|------|---------|
| `namespace.yaml` | `gh-leaked-tokens` namespace |
| `db-secret-store.yaml` | ESO SecretStore + `eso-db` SA to read the shared-Postgres user secret cross-namespace |
| `db-external-secret.yaml` | Materializes `DB_URL` (user `research_gh_leaks`, db `research_gh_leaks`) for the in-cluster Postgres Service |
| `vault-secret-store.yaml` | ESO SecretStore + `eso` SA to read this namespace's Vault KV mount (`gh-leaked-tokens/`) |
| `healthcheck-external-secret.yaml` | Materializes `HEALTHCHECK_URL` (healthchecks.io ping URL) from Vault |
| `pushgateway.yaml` | Pushgateway Deployment + PVC + Service |
| `prometheus.yaml` | Dedicated long-term Prometheus (10y, no size cap) + SA + ClusterRoleBinding + Service; scrapes only this namespace's gateway |
| `servicemonitor.yaml` | Points the gateway at the dedicated instance (`prometheus: gh-leaked-tokens`, `honorLabels: true`) |
| `cronjob.yaml` | The 15-minute `recheck` job |

(The Grafana datasource for the dedicated Prometheus lives in
`grafana/datasource-gh-leaked-tokens.yaml`, managed by the grafana app.)

## Monitoring the job itself

The recheck CLI pings a [healthchecks.io](https://healthchecks.io) check once at
the end of each run — the base URL on success, `…/fail` if the metrics push had
errors. A run that never happens (CronJob broken, image won't pull) or crashes
before finishing simply never pings, and healthchecks.io alerts on the overdue
ping. The URL is injected as `$HEALTHCHECK_URL` from Vault (see setup below);
when unset the ping is a no-op.

## Image

Built and pushed by the
[`build-push-harbor.yaml`](https://github.com/Shion1305/gh-base64token-investigate/blob/main/.github/workflows/build-push-harbor.yaml)
workflow in the source repo to
`harbor.shion1305.com/shion1305/gh-leaked-tokens` (pulled in-cluster as
`harbor.i.shion1305.com/...`). The image entrypoint runs `alembic upgrade head`
before the CLI, so schema migrations apply automatically on the next run.

## One-time setup (out of band)

These are NOT in the repo and must exist before the app syncs cleanly:

1. **Postgres user/db** — `research_gh_leaks` user and database are already
   declared in `postgres-shared/postgres-cluster.yaml`. The Zalando operator
   generates the credentials Secret
   `research_gh_leaks.postgres-shared.credentials.postgresql.acid.zalan.do`.
2. **Cross-namespace RBAC** — the `eso-db` SA's read access to that Secret is
   granted by `external-secrets/rbac-db-reader.yaml` (Role + RoleBinding
   `eso-db-gh-leaked-tokens`), synced by the external-secrets app.
3. **DB network access** — `postgres-shared` denies ingress by default
   (Cilium); `postgres-shared/networkpolicy.yaml` lists `gh-leaked-tokens` in
   the `:5432` allow-list so the CronJob can reach Postgres. (Synced by the
   shared-postgres app — same repo, but a different ArgoCD Application, so it
   must be applied for the recheck job to connect.)
4. **Vault healthcheck secret** — the `gh-leaked-tokens/` KV v2 mount, the
   `eso-gh-leaked-tokens` policy/role, and the ping URL itself must exist:
   ```sh
   vault secrets enable -path=gh-leaked-tokens -version=2 kv   # once
   bash vault/scripts/setup-eso-policies.sh                    # creates policy + role
   vault kv put gh-leaked-tokens/healthcheck url=https://hc-ping.com/<your-check-uuid>
   ```
   Optional: skip all of this and the job still runs — `HEALTHCHECK_URL` is an
   `optional` secret ref and the CLI no-ops on an empty URL (no ping, no error).

## Operating

```sh
# Trigger an immediate run instead of waiting for the schedule:
kubectl create job -n gh-leaked-tokens --from=cronjob/gh-leaked-tokens-recheck manual-$(date +%s)

# Watch the latest run:
kubectl logs -n gh-leaked-tokens -l job-name --tail=200 -f

# Inspect what's currently on the gateway:
kubectl port-forward -n gh-leaked-tokens svc/pushgateway 9091:9091
# then open http://localhost:9091
```
