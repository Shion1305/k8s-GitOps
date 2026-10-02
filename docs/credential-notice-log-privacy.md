# Credential notice access-log privacy

`credentials.research.shion.dev` uses capability URLs under `/r/` and `/s/`.
The two EnvoyProxy resources omit the whole site's access logs by matching
either the HTTP authority or TLS SNI. This covers errors, redirects, query
strings and encoded paths without relying on successful route selection or
path normalization. Matching is case-insensitive, permits an optional port
and trailing DNS dot, and excludes lookalike suffix/prefix hostnames.

The credential HTTPRoute attaches to `external` on `envoy-default` only.
The `home` proxy also receives the filter because direct or misrouted
requests can reach its unmatched listener. This does not attach the site to
`home`, add routes or change certificates. Requests are omitted if **either**
authority or SNI matches: a different HTTP authority on a connection whose
SNI is the credential site is intentionally omitted too. Logging is unchanged
when neither identity matches the credential site.

Each proxy has one custom setting with its type and format omitted. Envoy
Gateway therefore retains the version's default JSON fields and stdout sink
for other hosts, applies the filter to HTTP/TCP access logs and unmatched
listener errors, and removes the unfiltered default logger. Missing HTTP
attributes are handled explicitly so unrelated TLS/transport diagnostics
still work. Neither `Forwarded` nor `X-Forwarded-Host` controls this filter.

## Reproducible validation

Run `python3 scripts/verify-credential-access-logs.py` with egctl 1.9.0,
kustomize, yq, openssl and Docker available. CI runs the same command with
the deployed Envoy 1.39.0 image pinned by digest. `--translate-only` is useful
without Docker but does not establish runtime behavior.

The check translates each real GatewayClass separately using its current
proxy, listeners and credential/Harbor routes. All certificates are generated
for the test; production Secrets are never read. It compares generated access
logs with the unmodified default: locations, destinations, formats and the
existing listener response-flag filter must be preserved, with exactly one
filtered logger at each location.

An isolated Envoy then runs the generated HTTP and listener loggers. Synthetic
requests cover `/r/`, `/s/`, successful/rejected/error responses, no route,
redirects, queries, escaped slashes, encoded NUL, dot segments, uppercase
authority/SNI, ports, trailing dots and mismatched authority/SNI. Unrelated
hosts, lookalike hostnames, spoofed forwarding headers and unmatched TLS
connections must still log exactly once. No private marker may reach either
stdout or stderr. The test removes its container and temporary files.

## Rollout verification before sending links

This configuration check does not replace verification of the deployed chain.
Keep [#642](https://github.com/Shion1305/k8s-GitOps/issues/642) open until the
following evidence is recorded using synthetic markers only:

1. Confirm the live generated HTTP/TCP and listener configurations on every
   active proxy contain the filter and no unfiltered second logger.
2. Repeat the synthetic successful and rejected request matrix against public
   HTTPS and direct origins, including unmatched requests and redirects.
3. Search proxy stdout/stderr, application stdout/stderr and the active log
   collector/Loki ingestion for those markers. Confirm unrelated control
   requests still appear. Inspect any tracing or error collector added since
   this review; none is made safe merely by filtering Envoy access logs.
4. Verify the current DNS/proxy chain and any CDN logging before approval.
   The observed public DNS points directly to the OCI gateway; do not assume
   this remains true after a DNS/CDN change.
5. Record aggregate outcomes only. Never paste a real capability URL in an
   issue, log query, screenshot or test command.

The initial live rehearsal found 13 bearer-bearing lines across two readable
proxy logs, including an HTTP 500 response. One other proxy's logs could not
be read, so that sample did not establish full fleet coverage. Application
stdout/stderr had no marker matches in the retained sample. These observations
motivate this change; they are not evidence that the new filter is deployed.

The generated public HTTP connection managers use the immediate remote
address and zero trusted X-Forwarded-For hops. Envoy can still append to a
client-supplied X-Forwarded-For list. At review time, the application survey
helper selected the **first** value, which is not authenticated by that
configuration. Its trusted-client-address handling is tracked in
[application #152](https://github.com/Shion1305/gh-base64token-investigate/issues/152)
and needs a separate change
and spoofed-header verification before the survey audit trail is relied on.
This PR does not change shared forwarding behavior or claim to fix that
application boundary.

References: [Envoy Gateway access logs](https://gateway.envoyproxy.io/v1.9/tasks/observability/proxy-accesslog/),
[Envoy 1.39 request/connection attributes](https://www.envoyproxy.io/docs/envoy/v1.39.0/intro/arch_overview/advanced/attributes),
[egctl translation](https://gateway.envoyproxy.io/v1.9/tasks/operations/egctl/).
