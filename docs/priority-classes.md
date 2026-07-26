# Kubernetes Pod Priority Design

## Purpose

Pod priority is the cluster's last-resort admission control when a node cannot
fit every requested Pod. It determines scheduler ordering and which lower
priority Pods may be preempted; it does not reserve CPU or memory, guarantee
availability, or prevent kubelet eviction under memory pressure. Requests,
limits, replica placement, disruption budgets, and node capacity remain the
primary availability controls.

Every workload remains at Kubernetes' default priority (`0`) unless losing it
would block cluster management, traffic ingress, storage, or the image supply
chain. `globalDefault` is always `false`: a new workload must opt in explicitly
after its failure mode is understood.

## Tiers

| Priority | Class | Intended workloads | Preemption rule |
| --- | --- | --- | --- |
| `2000001000` | Kubernetes `system-node-critical` | Node-local Kubernetes and required node-health agents | Never assign to ordinary application workloads. |
| `2000000000` | Kubernetes `system-cluster-critical` | Cluster-wide Kubernetes control-plane add-ons | Never assign to ordinary application workloads. |
| `1000000000` | `longhorn-critical` | Storage control/data plane | Must stay above ingress and applications. |
| `2000000` | `envoy-gateway-critical` | Edge Gateway data plane | May preempt app-critical Pods; must not preempt storage or system Pods. |
| `1000000` | `argocd-critical`, `harbor-critical`, `postgres-operator-pod` | GitOps control plane and essential shared application services | May preempt default-priority workloads, but not other Pods in this tier. |
| `100000` | `github-readme-stats-app` | Existing repository-specific service tier | May preempt default-priority workloads, but not app-critical Pods. |
| `0` | no class | Normal applications, batch work, and optional services | May be preempted by any tier above. |

Classes at the same numeric value are deliberately peers. Kubernetes only
preempts lower values, so `harbor-critical` cannot displace Argo CD or another
app-critical workload. This keeps image distribution important without letting
it outrank the cluster components that reconcile or expose it.

## Harbor

Harbor is assigned `harbor-critical` (`1000000`) for its chart-rendered core,
portal, registry, jobservice, nginx, exporter, Redis, and Trivy Pods, as well
as the post-sync OIDC configuration Job. Registry availability is required for
image pulls and deployments, so Harbor must be schedulable ahead of
default-priority workloads. It remains below Envoy Gateway, storage, and
Kubernetes system work because those layers are prerequisites for reaching or
running Harbor.

All Harbor workloads are additionally pinned to `shion-ubuntu-2505`. Priority
only decides contention on that node; it cannot move a Pod elsewhere when the
node selector has made it ineligible.

## Operating rules

1. Prefer the existing tier whose failure impact matches the workload. Create a
   new class only when a distinct preemption relationship is necessary.
2. Do not use `system-*` classes for application workloads.
3. Specify `priorityClassName` in the Helm values or Pod template, and commit
   the corresponding `PriorityClass` manifest in the owning application.
4. Give every elevated workload realistic resource requests. A high priority
   Pod without requests can still cause resource pressure and kubelet eviction.
5. When adding or changing a class, update this document, identify its
   preemption victims, and test that the owning renderer emits the class name.
6. During an incident, inspect `kubectl get events` for `Preempted` and
   scheduling failures. Raise capacity or reduce requests before escalating
   more workloads into a higher tier.
