# Postmortem: instance-k8s-proxy node outage (2026-05-30)

**Status:** Resolved (node recovered via manual reboot)
**Incident window:** 2026-05-30 ~01:42–05:49 UTC (~10:42–14:49 JST)
**Severity:** High — a worker node holding the internal gateway became `NotReady` for ~4h.

> Evidence basis: all figures/timings below are from `journalctl -b -1` on the node
> (boot `db3f1171`, 2026-05-09 → 2026-05-30), `kubectl`, and repo manifests. Verified, not estimated.
> Numbers come from the kernel's authoritative `Out of memory: Killed process … anon-rss:` lines,
> not from the oom process-table dump (whose columns are easy to misparse).

## Impact

`instance-k8s-proxy` (`10.130.5.21`, Oracle Cloud arm64, **12 GB RAM, 2 vCPU, 0 swap**)
went `NotReady`. This node concentrates critical infra, so blast radius was wide:

- **Internal Envoy Gateway** (`10.130.5.21` → `*.i.shion1305.com`) — pod stuck `Terminating`.
- **ArgoCD control plane**, **kyverno** controllers — `Terminating` (ArgoCD rescheduled to `shion-ubuntu-2505` ~3h35m in and self-healed).
- **Longhorn** instance-manager + replicas; **vault** pods.
- ~18 ArgoCD apps showed `Degraded`/`OutOfSync` while the API reflected the frozen node.

No data loss. After recovery all pods returned `Running`, 0 stuck `Terminating`.

## Timeline (UTC)

| Time | Event |
|---|---|
| 05-10 → 05-19 | ws-stream pod cgroup-OOMKilled ~every 7–8h (contained, node fine). |
| **05-20 16:35:59** | oom-killer begins firing as node memory is exhausted. |
| **05-20 16:38:01–02** | **Node-wide OOM:** 13 `CONSTRAINT_NONE` (system-wide) kills in ~2s. Largest victim: **`java` (keycloak), anon-rss ≈ 1.14 GB, oom_score_adj 858**. Bystanders reaped: vault, envoy (internal gw), external-secrets webhook, node_exporter, memgator, discordbot, php. Node survived. |
| 05-20 16:43:53 | StatefulSet recreates `keycloak-0` on `shion-ubuntu-2505` (different node). |
| 05-20 → 05-30 | Node ran healthy ~9.5 days (single kubelet PID, no restarts). |
| 05-30 01:42:10 | Node Ready heartbeat stops updating at the API server (Lease cadence / observation lag — **the node itself was still running**). |
| **05-30 01:46:11** | **The outage:** node logging normally at full cadence (max 21s between lines), then the journal **cuts off instantly mid-activity** — abrupt VM termination. No OOM/panic/hung_task/lockup/IO error; no clean shutdown in wtmp. |
| 05-30 ~01:47 | Control plane taints node `unreachable`; pods → `Terminating`. |
| 05-30 ~05:40 | Manual Oracle Cloud console reboot (an earlier attempt did not take effect promptly). |
| 05-30 05:46:56 | OS boots (new bootID `91fe2931`, kernel auto-upgraded 6.17.0-1011 → -1014). |
| 05-30 05:49:32 | Node `Ready`; cluster recovers. |

## Root cause — TWO SEPARATE incidents (do not conflate)

An initial read blamed "a ws-stream memory leak." **That is wrong for both the 5/20 OOM and the 5/30 outage.**

### A. The 05-20 node-wide OOM — an over-committed node, triggered by Keycloak
- The single largest process the kernel killed was **`java` (keycloak-0), anon-rss ≈ 1.14 GB**, cgroup `kubepods-burstable-pod-a004e26f…` = pod UID `a004e26f-1041-4a7f-a01c-349d6618ee44`, `runAsUser: 1000`. Confirmed: the **current** `keycloak-0` carries that exact UID and was **recreated 16:43:53** (5 min after the kill) onto `shion-ubuntu-2505`.
- **But the victims only summed to ~1.4 GB.** The other ~10 GB was held by processes that *survived* — ~100+ co-located pods plus heavy node-resident Oracle Cloud agents seen in the OOM table (`oci-wlp`, `unifiedmonitoringagent`, `gomon`, `updater`, `agent`, `snapd`). So the node was **chronically memory-over-committed**, and the Keycloak JVM growth was the trigger that pushed it over the edge, not a single runaway.
- The node **did** have kubelet protection: `evictionHard memory.available: 300Mi`, `systemReserved`/`kubeReserved` 500Mi each (cpu 200m), `kubepods.slice memory.max ≈ 10.67 GiB`, `enforceNodeAllocatable: [pods]`. A fast allocation burst outran the soft-eviction loop, so the kernel OOM-killer fired before kubelet could evict — reservation is necessary but not sufficient against a sudden spike on a swap-less, over-committed node.
- Keycloak itself is **not** misconfigured today: `requests 1700Mi / limits 2Gi`, `JAVA_OPTS_APPEND=-Xms1g -Xmx1536m -XX:MaxMetaspaceSize=256m`. It is just larger than the other pods, so it had the highest non-system `oom_score`.
- **ws-stream** (`atc/ws-stream-deployment.yaml`, 512Mi limit) leaks too, but its limit keeps kills `CONSTRAINT_MEMCG` (pod-scoped) — noisy, never node-fatal. It is a red herring for this outage.

### B. The 05-30 outage — abrupt VM termination at the hypervisor layer (**NOT** a guest hang or OOM)

> An earlier draft of this section claimed a "silent guest hang with a 4-minute log gap (01:42→01:46)."
> **That was wrong** — it was an artifact of truncated SSH captures. A clean re-read of the on-node
> journal disproves it; the corrected analysis follows.

**The node was fully alive and logging normally right up to a hard cut.** Decisive forensics from
`journalctl -b -1` on the node (UTC):

- **No gap, no hang.** Between 01:30:00 and the last line, the **maximum silence between any two
  consecutive journal lines was 21 seconds** — i.e. completely normal cadence. There was no
  freeze and no 4-minute gap.
- **Normal forward progress until the end.** The final lines (01:46:00–01:46:11) show the kernel
  creating a new container veth (`eth0: renamed from tmpcc07b`), kubelet actively cleaning up pod
  volumes / removing cgroup slices / syncing pods, containerd pulling images, and even an SSH
  brute-force probe being rejected at 01:46:08 — all routine activity.
- **The journal then stops instantly at 01:46:11**, mid-activity, with **no shutdown sequence**
  (no systemd "Stopping …" units, no `reboot.target`), **no kernel panic / BUG / oops / call
  trace**, **no hung_task / soft-lockup / hard-lockup / rcu-stall / watchdog**, **no OOM**, and
  **no I/O / EXT4 / MCE / thermal** errors.
- `last -x reboot` shows the prev boot ended with **no matching "shutdown system down" entry**
  (every other reboot — 5/9, 5/6, 5/2, 4/29 — has a clean shutdown pair). This was a **hard stop**.
- The control-plane "heartbeat froze at 01:42:10" was a **red herring**: that is just the Node
  Lease renewal cadence / observation lag at the API server. The node itself kept running and
  logging for ~4 more minutes, until 01:46:11.

**Conclusion:** a process that is healthy and logging at full cadence one instant and produces
**zero** output the next — with no guest-side distress of any kind and no clean shutdown — is the
signature of the **VM being killed/powered-off instantaneously from outside the guest** (Oracle
Cloud hypervisor layer): an abrupt host-level stop, host hardware fault, failed/forced
live-migration, or an infra-side power event. A guest kernel hang, disk-IO stall, or OOM would all
leave traces (lockup/hung_task, IO errors, OOM-killer lines) and would *not* cut the log mid-line
at full cadence — so those are **ruled out** by the evidence.

**Still unconfirmed (needs Oracle-side data):** the *specific* host event. Guest logs cannot
distinguish "host crashed" from "host intentionally stopped the VM." To close this:
- Oracle Cloud **Console → instance → Work Requests / Maintenance events** around 2026-05-30 01:46 UTC.
- Oracle **instance console history** (capture before it rolls off).
- Oracle host/VM **metrics** for 01:40–01:47 UTC.

Note: kdump is **not** configured and `/var/crash` is empty, and there is **no
`/var/log/oracle-cloud-agent/`** on this image — so no guest-side crash artifact was or could be
captured. Enabling kdump would let us distinguish a (future) guest kernel crash from a host event.

## Aftermath issues (post-reboot, currently open)

- **🔴 ALL THREE Vault pods `1/2 CrashLoopBackOff` → cluster-wide secret delivery is broken (P1, pre-existing ~43h).** Failure is **`exec: vault: Operation not permitted` / "Vault requires the IPC_LOCK capability"** (exit 126), NOT "sealed". The `hashicorp/vault:2.0.1` container (chart 0.32.0, HA raft) tries to `mlock` memory but the pod has **no `IPC_LOCK` capability and no `disable_mlock`** in `vault/values.yaml`. **vault-0 has 514 restarts over 43h on the *healthy* node** → independent of the node hang; it's a config regression. **Impact:** every Vault-backed `ExternalSecret` is `SecretSyncedError` (atc, harbor, freqtrade, cert-manager cloudflare-api-token, grafana/monitoring oauth, lumos-bot discord, nc-press, github-readme-stats…). Only `k8s-postgres`-backed ESOs (DB creds) still sync. This is the real driver behind much of the `Degraded` app list.
- **gh-analysis** `CrashLoopBackOff`: `gh-spam-analysis-proj:v0.1.7` — `no match for platform in manifest` = the image lacks an **arm64** variant for these arm64 nodes. Pre-existing (it was the last log line before the freeze); unrelated to the hang.
- **langfuse-redis-primary-0** `CrashLoopBackOff` (3036 restarts) — long-standing, unrelated.

## Remediation

### Immediate
- [ ] **🔴 Fix Vault `IPC_LOCK`** — highest priority; all Vault-backed secret delivery has been down ~43h. **Root cause: Renovate commit `3e2ca42` (2026-05-28 02:27 UTC) bumped `hashicorp/vault` 2.0.0 → 2.0.1**, whose entrypoint now *hard-fails* without `IPC_LOCK` (`Vault requires the IPC_LOCK capability … exec: vault: Operation not permitted`). The values never granted the cap; 2.0.0 tolerated its absence, 2.0.1 does not. The crashloop age (43h) matches the commit exactly. **Fix:** in `vault/values.yaml` add `disable_mlock = true` to the `server.ha.raft.config` HCL (simplest for containerized Vault), or grant `IPC_LOCK` via `server.extraSecurityContext`. Then confirm ESOs flip back to `SecretSynced` and consider whether to allowlist Vault from Renovate automerge.
- [ ] **Pull Oracle console history** for 05-30 01:42–01:46 and attach here to confirm the hang cause.

### Short-term
- [ ] **De-overcommit the node**: on 5/20 the node ran ~100 pods plus heavy node-resident Oracle agents (`oci-wlp`, `unifiedmonitoringagent`, `gomon`, …) and page cache, with only ~1.4 GB recoverable by killing the OOM victims — i.e. nearly all 12 GB was committed. Either cap pod count/size on this node or add memory headroom. (Measure real usage once metrics-server is back; it was unavailable during this incident.)
- [ ] **PriorityClass + anti-affinity / taints**: keep large pods (keycloak) and leaky batch (atc) off the node that hosts the internal gateway + ArgoCD + Longhorn + vault, so a trigger pod can't reap critical infra.
- [ ] **Fix gh-analysis image**: publish an arm64 (or multi-arch) `gh-spam-analysis-proj`, or pin the pod to an amd64 node. `gh-analysis/`.
- [ ] **Alerting**: `KubeNodeNotReady`, container OOMKill / restartCount growth, node `MemAvailable` low. The 4h `NotReady` and the multi-day leaks were all found by a human, not an alert.

### Long-term
- [ ] **Reduce SPOF**: a single 12 GB / 2 vCPU node carrying internal gateway + control plane + Longhorn + vault + many pods is over-concentrated and over-committed. Relocate or replicate the critical listeners; consider a larger node.
- [ ] **Fix the ws-stream app leak** (upstream `crypto-auto-trading`, out of repo scope).
- [ ] **Crash capture**: enable kdump + Oracle VM host monitoring so the next silent hang isn't opaque.

## Lessons

- **Don't conflate co-occurring symptoms.** The loud ws-stream leak was a red herring; the 5/20 OOM was an over-committed node tripped by the Keycloak JVM; the 5/30 outage was an abrupt **hypervisor-layer VM termination** with no guest cause at all.
- **A frozen API-server heartbeat ≠ a frozen node.** The 01:42:10 Lease freeze looked like the failure moment but the node logged normally for 4 more minutes; always corroborate the heartbeat against on-node logs before concluding "the node hung."
- **An instant log cut at full cadence, with no shutdown sequence and no kernel distress, points outside the guest.** A guest hang/OOM/IO-stall leaves traces (lockup, hung_task, OOM lines, IO errors) and tapers; an external kill does not.
- **Trust the kernel's `Killed process … anon-rss:` lines, not the oom process-table dump** — the latter's columns are trivially misparsed (it led to two wrong attributions during this very investigation).
- An **over-committed, swap-less node** can be tipped into a node-wide OOM by any one pod's burst; eviction thresholds don't reliably catch a fast multi-GB allocation.
- **Persistent journaling was decisive** — but pinning a host-level event needs **Oracle-side** evidence (Work Requests / maintenance events / console history) the guest can't provide; collect it immediately, before it rolls off. Enable kdump to capture any future guest kernel crash.
