# Private notification dashboard

The application dashboard at `https://credentials.research.shion.dev/admin`
is a read-only projection of reviewed notification artifacts, tracked in
[application issue #156](https://github.com/Shion1305/gh-base64token-investigate/issues/156).
It provides recipient review, email previews and CSV export. It does not
register reports, create drafts, approve cases or send mail. The displayed
generation time identifies the snapshot; it is not a live delivery ledger.

## Configuration

The existing namespace `SecretStore` named `vault` reads the KV v2 mount
`gh-leaked-tokens/`. The two new paths are independent of database credentials:

| Vault path | Properties | Kubernetes Secret |
| --- | --- | --- |
| `gh-leaked-tokens/credential-exposure-admin-auth` | `username`, `password` | `credential-exposure-admin-auth` |
| `gh-leaked-tokens/credential-exposure-admin-review` | `dashboard` (JSON string) | `credential-exposure-admin-review` |

ESO maps the authentication properties to `ADMIN_DASHBOARD_USERNAME` and
`ADMIN_DASHBOARD_PASSWORD` through Secret references. The review property
becomes the file `/var/run/notification-dashboard/dashboard.json`, selected by
`ADMIN_DASHBOARD_DATA_FILE`. The directory mount is read-only, uses mode `0440`
and the existing Pod group `10001`, and does not use `subPath`.

Both Secrets are optional so their absence does not block the public site.
The reviewed application must deny dashboard access when authentication is
missing and return no review data when the file is absent or invalid. Publish
that application image before merging this deployment change; the Argo CD
application automatically reconciles merges. No Gateway, database grant,
Vault policy or request-log change is needed.

## Provisioning and refresh

Use an authenticated operator connection to `https://vault.i.shion1305.com`
or a local port-forward to `svc/vault-active` in namespace `vault`. Do not use
the public CI hostname, whose path allowlist excludes these operator writes.

Generate a random password and keep it in a private local file. Store only the
minimal exported dashboard projection, not the raw research or credential
dataset. Read both inputs from files and pass JSON on stdin to Vault; never put
passwords, recipient records or previews in command arguments, Git, container
images or terminal output. For initial creation, use KV v2 compare-and-set
version `0` to refuse replacement of an existing path. For a later refresh,
use the current version as the compare-and-set guard and preserve any other
properties at that path.

Keep the exported JSON below 900 KiB; Kubernetes limits each Secret to 1 MiB.
ESO checks Vault every five minutes. A normal directory-mounted Secret update
then reaches the Pod eventually; the app reads the current snapshot for each
request. Authentication is injected as environment variables, so changing or
initially supplying its Secret requires an approved application restart.
Updating the JSON alone does not require one. See the
[Kubernetes Secret update rules](https://kubernetes.io/docs/concepts/configuration/secret/).

After provisioning, inspect only ExternalSecret Ready conditions and Secret
metadata. After the approved application rollout, verify that unauthenticated
and incorrect-password requests disclose no table, preview or CSV; valid
credentials show the expected generation time; and public pages remain
available. Missing or malformed configuration must keep the dashboard closed.
Do not paste real recipient records or credentials into PRs or diagnostics.
