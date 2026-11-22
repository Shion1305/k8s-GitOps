# Clinic slot monitor

A one-shot clinic availability check managed by Argo CD. The CronJob runs at
minute zero of each hour in `Asia/Tokyo`, checks four months, and exits. It is
stateless: no PVC, database, lock file, or writable application volume is needed.

Each run sends the currently available appointments using a stable PagerDuty
deduplication key per appointment. PagerDuty groups matching events while an
alert remains open. After it is resolved, a later check can create a new alert
if the appointment is still available. Reopened appointments reuse the same key;
the monitor does not retain notification or availability history.

The schedule is **enabled** (`suspend: false`). After this change is merged and
Argo CD syncs it, Jobs run hourly and may notify PagerDuty for real availability.
Verify the shared key and registry access before merging.

## Shared PagerDuty key

The namespace opts into the shared secret using
`secrets.shion1305.com/pagerduty: enabled`.

External Secrets reads the `routing-key` field from the Vault KV v2 entry
`system/pagerduty` through `ClusterSecretStore/vault-pagerduty`. It creates
`Secret/pagerduty-events` in opted-in namespaces. The monitor reads the key from
the mounted file `/secrets/pagerduty/routing-key`; no secret value belongs in Git.
Other applications can use the same key by opting their namespace into this
distribution. Rotation is performed once in Vault and refreshed within five
minutes. A Job reads the key at startup, so an already-running Job uses its
original value until it exits.

The Vault policy and Kubernetes auth role are recorded in
`vault/scripts/setup-eso-policies.sh`. The role is bound only to ServiceAccount
`external-secrets/external-secrets` and can read only `system/data/pagerduty`.

## Image and activation

The stateless image is pinned to the published digest from application commit
`0f189df25e2a273b0cd5b87bbfe09020f74905ef`. Harbor pull credentials are delivered
directly to this namespace through the existing shared Harbor secret mechanism.

The internal image hostname controls this workload's route to Harbor; it does
not restrict the same artifact through other Harbor endpoints. The existing
public Registry v2 route also supports pulls, so a public Harbor project cannot
be assumed private based on the hostname used here. Registry access must be
resolved separately before merging the enabled schedule. This change does not modify
registry visibility or gateway access rules.

Before merging:

1. Confirm the image is protected on every exposed registry endpoint and that
   the pinned stateless image can be pulled by cluster nodes.
2. Verify that `system/pagerduty` contains the intended Events API v2 integration
   key in the `routing-key` field. Confirm the account region; the current flag
   uses the US Events API. The application never sends a synthetic test event.

After merge and Argo CD synchronization:

1. Confirm `vault-pagerduty` is ready and the namespace's `pagerduty-events` and
   `harbor-pull` secrets are synchronized. An hourly Job cannot start its monitor
   container until its required secret is available.
2. Confirm the first scheduled Job succeeds. If needed, run a separate manual
   Job with `--dry-run` added to verify calendar access without sending events.
   Keep its output within private operational systems. A run with no available
   appointments does not verify PagerDuty's acceptance of the key.
3. To stop checks, change `spec.suspend` to `true` through Git; Argo CD will
   reconcile imperative changes back to Git. Suspension prevents future Jobs;
   it does not stop one that is already running.

The cluster's existing failed-Job alert covers failures. A separate rule warns
when an enabled monitor has no successful check for more than three hours,
including when it has never succeeded. It is suppressed while the CronJob is
suspended. Alerts use the existing infrastructure notification route, not the
application's availability-event sender. No Service or Ingress is needed.
