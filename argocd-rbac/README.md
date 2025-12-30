# RBAC Resources

This directory contains critical RBAC (Role-Based Access Control) resources that are essential for cluster operation.

## Structure

- `core/`: Core Kubernetes RBAC resources that must always exist
  - `cluster-admin-clusterrole.yaml`: The cluster-admin ClusterRole with full permissions
  - `cluster-admin-clusterrolebinding.yaml`: Binding for system:masters group
  - `default-roles.yaml`: Default admin, edit, and view roles

## Purpose

These resources are managed by ArgoCD to ensure:

1. **Automatic Recovery**: If RBAC resources are accidentally deleted, ArgoCD will automatically recreate them
2. **Version Control**: All RBAC changes are tracked in Git
3. **Audit Trail**: Changes to critical permissions can be reviewed via Git history
4. **Disaster Recovery**: Complete RBAC configuration can be restored from this repository

## Management

These resources are deployed via the `rbac-core` ArgoCD Application with:

- **Auto-sync enabled**: Changes in Git are automatically applied to the cluster
- **Self-heal enabled**: Deleted or modified resources are automatically restored
- **Replace sync option**: Ensures resources are properly updated even if managed externally

## Important Notes

⚠️ **WARNING**: These resources grant full cluster access. Any changes should be carefully reviewed.

- The `cluster-admin` ClusterRole grants unlimited access to all resources
- The `cluster-admin` ClusterRoleBinding grants this access to the `system:masters` group
- Modifying or deleting these resources can lock you out of the cluster

## Recovery Procedure

If you lose cluster access due to RBAC issues:

1. SSH into the control plane node
2. Temporarily disable RBAC:
   ```bash
   sudo sed -i 's/--authorization-mode=Node,RBAC/--authorization-mode=AlwaysAllow/' /etc/kubernetes/manifests/kube-apiserver.yaml
   ```
3. Wait 30 seconds for API server to restart
4. Apply this directory:
   ```bash
   kubectl apply -f rbac/core/
   ```
5. Re-enable RBAC:
   ```bash
   sudo sed -i 's/--authorization-mode=AlwaysAllow/--authorization-mode=Node,RBAC/' /etc/kubernetes/manifests/kube-apiserver.yaml
   ```
