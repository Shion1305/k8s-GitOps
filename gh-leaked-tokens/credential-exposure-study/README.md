# Credential exposure notices

This bundle mirrors the reviewed application deployment from
[`gh-base64token-investigate/survey/deploy`](https://github.com/Shion1305/gh-base64token-investigate/tree/825e7a966265ded067490a14f7955441c0ccd765/survey/deploy).
Keep application deployment changes aligned with that source and its
[release runbook](https://github.com/Shion1305/gh-base64token-investigate/blob/main/survey/deploy/README.md).

Merging this bundle enables the existing `gh-leaked-tokens` Argo CD application
to deploy the site automatically. The `shared-postgres` and `external-secrets`
applications independently reconcile the database roles and credential-reader
RBAC. Before merging, publish the reviewed image, apply the reviewed migration,
verify the research wildcard certificate, and arrange the grant step below.

The Postgres operator creates `survey_app` and `disclosure_report_app` logins
with generated credentials, plus the `survey_web` and `disclosure_report_web`
NOLOGIN roles. None owns a database. The dedicated `eso-credential-exposure-db`
ServiceAccount can read only those two login Secrets. ESO materializes
`credential-exposure-study-db` and `credential-exposure-reports-db`, each with a
`DB_URL` key targeting `research_gh_leaks`. The pipeline database login is not
an application login.

After the operator creates all four roles, apply the versioned grant scripts
from the reviewed application checkout using an administrator session. The
pipeline owner cannot create roles or grant role membership. Discover the
current primary Pod with the operator's `cluster-name=postgres-shared,spilo-role=master`
labels, then pass the SQL through its local PostgreSQL socket; do not extract
or publish an administrator password:

```sh
kubectl -n postgres-operator-deployment get pods \
  -l cluster-name=postgres-shared,spilo-role=master
kubectl -n postgres-operator-deployment exec -i "$POSTGRES_PRIMARY_POD" -- \
  psql -X -U postgres -d research_gh_leaks -v ON_ERROR_STOP=1 \
  -v survey_role=survey_web -v survey_login=survey_app -f - \
  < survey/scripts/provision_access.sql
kubectl -n postgres-operator-deployment exec -i "$POSTGRES_PRIMARY_POD" -- \
  psql -X -U postgres -d research_gh_leaks -v ON_ERROR_STOP=1 \
  -v report_role=disclosure_report_web -v report_login=disclosure_report_app -f - \
  < survey/scripts/provision_shared_report_access.sql
```

Verify the narrow grants, both ExternalSecrets' Ready conditions, and the
absence of broader direct or inherited permissions. Once both Secrets and
grants are ready, restart the application and verify its digest and route.
The shared-report Secret is optional at Pod creation, so an earlier Pod can
start without it and must be restarted to receive `SHARED_REPORT_DB_URL`.

The `latest` image is resolved when a Pod starts. Publishing a replacement alone
does not restart a running Pod; verify the deployed digest after each rollout.
Research participation starts closed. A healthy public page does not verify
shared reports or authorize delivery: rehearse a synthetic report with the
restricted role, verify response-status persistence and private-path log
exclusion, and complete recipient/evidence review before sending real notices.
The separate [bearer-log exclusion task](https://github.com/Shion1305/k8s-GitOps/issues/642)
is a delivery prerequisite. This bundle does not change shared Gateway logs.
