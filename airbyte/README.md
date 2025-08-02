# Airbyte Configuration

This directory contains the configuration for Airbyte that integrates with a PostgreSQL database managed by the Zalando postgres-operator.

## Architecture

- **Database**: PostgreSQL cluster named "airbyte" in the `postgres-operator-deployment` namespace
- **Credentials**: Managed by the postgres-operator and replicated to the airbyte namespace
- **Secret Replication**: Automated using ArgoCD PreSync hooks

## Components

### values.yaml

Contains the Helm values for the Airbyte deployment, configured to use an external PostgreSQL database.

### secrets.yaml

- **Secret**: Empty `airbyte-airbyte-secrets` managed by ArgoCD with placeholder values

### secret-sync.yaml

- **ServiceAccount**: `secret-replicator` with necessary RBAC permissions
- **ClusterRole**: Allows reading secrets from any namespace and updating the airbyte secrets
- **Job**: ArgoCD PreSync hook that patches the ArgoCD-managed secret with PostgreSQL credentials from the postgres-operator

## Database Connection Details

- **Host**: `airbyte.postgres-operator-deployment.svc.cluster.local`
- **Port**: `5432`
- **Database**: `airbyte`
- **User**: `airbyte`
- **Password**: Referenced from secret `airbyte-airbyte-secrets` with key `DATABASE_PASSWORD`

## Security Considerations

- Passwords are never stored in Git
- Secret replication is handled automatically by Kubernetes Jobs
- RBAC permissions are minimal and specific to the required resources
- The secret replication job runs as an ArgoCD PreSync hook to ensure secrets are available before Airbyte starts

## Deployment

This configuration is deployed automatically via ArgoCD using the application defined in `apps/airbyte-app.yaml`.
