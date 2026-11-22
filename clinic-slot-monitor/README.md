# Clinic slot monitor

A one-shot clinic availability check managed by Argo CD. The CronJob runs at
minute zero of each hour in `Asia/Tokyo`, checks four months, and exits. It is
stateless: no PVC, database, lock file, or writable application volume is needed.

Each run sends the currently available appointments using a stable PagerDuty
deduplication key per appointment. PagerDuty groups matching events while an
alert remains open. After it is resolved, a later check can create a new alert
if the appointment is still available. Reopened appointments reuse the same key;
the monitor does not retain notification or availability history.

The initial deployment is **suspended**. Merging the manifests creates the
configuration but does not schedule checks or send notifications.

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

The image reference is a placeholder pending an approved stateless application
build. Replace it with that build's published immutable digest before merging
this deployment change. The earlier stateful image is incompatible with this
configuration. Harbor pull credentials are delivered directly to this namespace
through the existing shared Harbor secret mechanism.

The internal image hostname controls this workload's route to Harbor; it does
not restrict the same artifact through other Harbor endpoints. The existing
public Registry v2 route also supports pulls, so a public Harbor project cannot
be assumed private based on the hostname used here. Registry access must be
resolved separately before enabling the schedule. This change does not modify
registry visibility or gateway access rules.

Before activation:

1. Confirm the image is protected on every exposed registry endpoint. After the
   stateless application change is approved and its image is published, replace
   the image placeholder with its digest and confirm cluster nodes can pull it.
2. Confirm `vault-pagerduty` is ready, the namespace's `pagerduty-events` and
   `harbor-pull` secrets are synchronized. Confirm
   the PagerDuty integration region; the current flag uses the US Events API.
3. Run one manual Job from the suspended CronJob with `--dry-run` added. Check
   image pulling and calendar access; this mode does not send events.
   Keep its output within private operational systems.
4. Run one normal manual Job to check mounted-secret access and normal execution.
   Only actual availability may generate an event; do not send synthetic test
   incidents. A run without availability does not validate PagerDuty acceptance.
5. Change `spec.suspend` to `false` through a reviewed change and confirm the
   next hourly Job succeeds. To stop checks, suspend through Git again; Argo CD
   will reconcile imperative changes back to Git.

The cluster's existing failed-Job alert covers failures. A separate rule warns
when an enabled monitor has no successful check for more than three hours,
including when it has never succeeded. It is suppressed while the CronJob is
suspended. Alerts use the existing infrastructure notification route, not the
application's availability-event sender. No Service or Ingress is needed.
