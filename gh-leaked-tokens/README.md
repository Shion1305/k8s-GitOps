# gh-leaked-tokens

Periodic re-validation of already-discovered leaked API tokens, exported to
Prometheus. This is the in-cluster deployment of the `recheck` command from
[`gh-base64token-investigate`](https://github.com/Shion1305/gh-base64token-investigate).

## What it does

A CronJob runs `cli.py recheck` every 15 minutes. For each token already in the
research DB it re-probes the provider's API, records any **valid → invalid**
transition (the moment a leaked token gets disabled) to Postgres history, and
**pushes** every result to a Pushgateway. kube-prometheus-stack scrapes the
gateway, so the `gh_token_valid` gauge over successive runs becomes the
token-disablement time-series the report audit trail depends on.

## Why a Pushgateway

`recheck` is a short-lived batch job — Prometheus can't scrape a pod that has
already exited. The job pushes to an always-on Pushgateway (Deployment + PVC for
persistence across restarts) and Prometheus scrapes that instead. The
ServiceMonitor sets `honorLabels: true` so the per-token `job`/`instance` labels
the job pushes are not overwritten by the scrape.

## Components

| File | Purpose |
|------|---------|
| `namespace.yaml` | `gh-leaked-tokens` namespace |
| `db-secret-store.yaml` | ESO SecretStore + `eso-db` SA to read the shared-Postgres user secret cross-namespace |
| `db-external-secret.yaml` | Materializes `DB_URL` (user `research_gh_leaks`, db `research_gh_leaks`) for the in-cluster Postgres Service |
| `pushgateway.yaml` | Pushgateway Deployment + PVC + Service |
| `servicemonitor.yaml` | Tells kube-prometheus-stack to scrape the gateway (`release: kube-prometheus-stack`, `honorLabels: true`) |
| `cronjob.yaml` | The 15-minute `recheck` job |

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
