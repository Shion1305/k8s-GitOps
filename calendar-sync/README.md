# Calendar sync

Runs `Shion1305/calendar-sync` hourly at minute 17 (Asia/Tokyo). It copies
connpass subscription events into the configured destination Google Calendar
and preserves copies after events disappear from the source feed. Restored
`connpass_event_id` / `connpass_sync_key` markers and legacy sync properties
are recognized; archival descriptions and `connpass_import_batch` survive.

## Activation status

The CronJob is initially **suspended**. Activate it after provisioning the
Google credentials in Vault and verifying a read-only sync from the cluster.

Application code: https://github.com/Shion1305/calendar-sync/pull/3

Published source commit: `eccc837b0c8748ccc30230f525aef01b6f6d0cee`.
Pinned image digest: `sha256:7f550a939974b8c4626728a22e72f3289520c807728a813b29921dff3295639c`.
[Successful signed publication](https://github.com/Shion1305/calendar-sync/actions/runs/45716355782).

To activate:

1. Review the application PR, then the deployment PR. Review the image's source
   commit and pinned digest below. Merging deploys the suspended CronJob through
   the root Argo CD application.
2. In the application checkout, run `go run . --authorize` using the local
   `config.yaml` and `credentials.json`. Complete the Google authorization,
   then inspect `go run . --dry-run`. Neither command writes calendar events.
3. Authenticate to Vault using the normal operator login. Run:

   ```sh
   export VAULT_ADDR=https://vault.i.shion1305.com
   ./calendar-sync/bootstrap-secrets.sh /path/to/local/calendar-sync
   ```

   This enables the dedicated KV v2 mount if absent, stores the three files at
   `calendar-sync/google`, and grants only read access to that entry via Vault
   role `eso-calendar-sync`, bound to ServiceAccount `calendar-sync/eso`.
   Re-running the script rotates the stored files; it never prints them.
4. After merge/sync, verify `SecretStore/vault`, `ExternalSecret/calendar-sync-google`,
   and the namespace's `harbor-pull` Secret are ready. The shared Harbor ESO
   delivery includes this namespace, avoiding a first-Pod credential race.
5. Run a one-off Job with `--dry-run` appended to its container arguments and
   check the planned counts/IDs. Keep calendar information in private systems.
6. Change `spec.suspend` to `false` in a reviewed PR to start hourly writes.
   The first normal run adopts current source matches; past restores absent
   from the current feed remain untouched and are never deleted.

## Runtime

The application runs once per Job, with an eight-minute timeout, a ten-minute
Job deadline and `concurrencyPolicy: Forbid`. Failure exits nonzero and is
covered by the cluster's existing failed-Job monitoring. The process has no
Kubernetes API token, guests/notifications are not copied, and no inbound
Service, Ingress or PVC is required.

OAuth credentials, token, and calendar IDs are stored in Vault rather than
Git, materialized into `Secret/calendar-sync-google`, and mounted read-only.
Access tokens refresh in memory. If Google revokes the refresh token, repeat
local authorization and upload it; ESO refreshes within five minutes, and the
next Job reads the replacement files.

The image supports amd64 and arm64. CI publishes commit-SHA tags and keyless
signatures through the shared Harbor action; this deployment uses an immutable
digest. New images require a reviewed digest change in this repository.
