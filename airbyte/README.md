# Airbyte Configuration

This directory contains the configuration for Airbyte that integrates with a PostgreSQL database managed by the Zalando postgres-operator.

## Architecture

- **Database**: PostgreSQL cluster named "airbyte" in the `postgres-operator-deployment` namespace
- **Credentials**: Managed by the postgres-operator and replicated to the airbyte namespace
- **Secret Replication**: Automated using ArgoCD PreSync hooks

## Components

### values.yaml
Contains the Helm values for the Airbyte deployment, configured to use an external PostgreSQL database.

### secret-sync.yaml
- **ServiceAccount**: `secret-replicator` with necessary RBAC permissions
- **ClusterRole**: Allows reading secrets from any namespace and creating/updating the airbyte secrets
- **Job**: ArgoCD PreSync hook that transforms PostgreSQL credentials from the postgres-operator format to Airbyte's expected format

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
