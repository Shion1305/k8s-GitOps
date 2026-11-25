# Calendar sync

Runs `Shion1305/calendar-sync` hourly at minute 17 (Asia/Tokyo). It copies
connpass subscription events into the configured destination Google Calendar
and preserves copies after events disappear from the source feed. Restored
`connpass_event_id` / `connpass_sync_key` markers and legacy sync properties
are recognized; archival descriptions and `connpass_import_batch` survive.

## Deployment

Application code: https://github.com/Shion1305/calendar-sync/pull/3

The CronJob pulls `harbor.i.shion1305.com/shion1305/calendar-sync:latest`
from Harbor each time a Pod starts. The application's default branch publishes
the tag after testing and signing the multi-architecture image.

### Provision or renew credentials

1. To pause scheduled writes during credential maintenance, set
   `spec.suspend` to `true` in Git and wait for Argo CD to sync.
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
4. Verify `SecretStore/vault`, `ExternalSecret/calendar-sync-google`,
   and the namespace's `harbor-pull` Secret are ready. The shared Harbor ESO
   delivery includes this namespace, avoiding a first-Pod credential race.
5. Run a one-off Job with `--dry-run` appended to its container arguments and
   check the planned counts/IDs. Keep calendar information in private systems.
6. If you paused the schedule, restore `spec.suspend` to `false` through Git.
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

The image supports amd64 and arm64. The application's Test and publish workflow
records the signed digest for each published build. Completed Pods report the
image they used in their container status.
