# Zalando PostgreSQL Operator

This setup provides on-demand PostgreSQL databases using the Zalando PostgreSQL Operator.

## Features

- **Automated PostgreSQL cluster provisioning**
- **High Availability** with automatic failover
- **Connection pooling** with PgBouncer
- **Automated backups** and point-in-time recovery
- **Monitoring** with built-in metrics
- **User and database management**
- **Scaling** and resource management
- **SSL/TLS** encryption

## Architecture

- **Operator**: Manages PostgreSQL clusters across all namespaces
- **Spilo**: PostgreSQL image with Patroni for HA
- **PgBouncer**: Connection pooler for high-performance applications
- **Postgres Exporter**: Metrics collection for monitoring

## Quick Start

### 1. Deploy the Operator

The operator is deployed via ArgoCD:

```bash
kubectl apply -f apps/postgres-operator-app.yaml
```

### 2. Create a PostgreSQL Cluster

Example development cluster:

```yaml
apiVersion: "acid.zalan.do/v1"
kind: postgresql
metadata:
  name: my-postgres
  namespace: my-app
spec:
  teamId: "my-team"
  volume:
    size: 10Gi
    storageClass: local-storage
  numberOfInstances: 1
  users:
    myuser:
    - login
    - createdb
  databases:
    mydb: myuser
  postgresql:
    version: "16"
```

### 3. Connect to Your Database

```bash
# Get connection info
./manage-postgres.sh connect my-postgres

# Get user credentials
kubectl get secret my-postgres.myuser -o jsonpath='{.data.password}' | base64 -d

# Connect
psql -h my-postgres.my-app.svc.cluster.local -U myuser -d mydb
```

## Management Commands

Use the included management script:

```bash
# List all clusters
./manage-postgres.sh list

# Get cluster status
./manage-postgres.sh status dev-postgres

# Get connection information
./manage-postgres.sh connect dev-postgres

# List users and credentials
./manage-postgres.sh users dev-postgres

# Scale a cluster
./manage-postgres.sh scale prod-postgres 3

# Show logs
./manage-postgres.sh logs dev-postgres

# Trigger backup
./manage-postgres.sh backup dev-postgres
```

## Cluster Specifications

### Basic Cluster

```yaml
apiVersion: "acid.zalan.do/v1"
kind: postgresql
metadata:
  name: basic-postgres
  namespace: default
spec:
  teamId: "basic-team"
  volume:
    size: 1Gi
  numberOfInstances: 1
  users:
    user1: []
  databases:
    db1: user1
  postgresql:
    version: "16"
```

### High Availability Cluster

```yaml
apiVersion: "acid.zalan.do/v1"
kind: postgresql
metadata:
  name: ha-postgres
  namespace: production
spec:
  teamId: "prod-team"
  volume:
    size: 100Gi
    storageClass: fast-ssd
  numberOfInstances: 3  # 1 master + 2 replicas
  users:
    app_user:
    - login
    - createdb
    readonly_user:
    - login
  databases:
    appdb: app_user
  postgresql:
    version: "16"
    parameters:
      max_connections: "500"
      shared_buffers: "2GB"
  resources:
    requests:
      cpu: 2
      memory: 4Gi
    limits:
      cpu: 4
      memory: 8Gi
  enableConnectionPooler: true
  enableReplicaConnectionPooler: true
```

## User Management

### User Types

- **Superuser**: Full database privileges
- **createdb**: Can create databases
- **login**: Can connect to database
- **replication**: Can perform replication

### Creating Users

Add users to the cluster spec:

```yaml
users:
  admin:
  - superuser
  - createdb
  app_user:
  - login
  readonly_user:
  - login
  backup_user:
  - login
  - replication
```

### Getting Credentials

```bash
# Username
kubectl get secret <cluster>.<username> -o jsonpath='{.data.username}' | base64 -d

# Password
kubectl get secret <cluster>.<username> -o jsonpath='{.data.password}' | base64 -d
```

## Database Management

### Creating Databases

Add databases to the cluster spec:

```yaml
databases:
  app_db: app_user      # database: owner
  analytics: app_user
  logs: readonly_user
```

### Connection Endpoints

- **Master**: `<cluster>.<namespace>.svc.cluster.local:5432`
- **Replica**: `<cluster>-repl.<namespace>.svc.cluster.local:5432`
- **Pooler**: `<cluster>-pooler.<namespace>.svc.cluster.local:5432`

## Backup and Recovery

### Automatic Backups

Configure in the operator:

```yaml
configLogicalBackup:
  logical_backup_schedule: "30 00 * * *"  # Daily at 00:30
  logical_backup_provider: "s3"
  logical_backup_s3_bucket: "my-backup-bucket"
```

### Manual Backup

```bash
./manage-postgres.sh backup my-postgres
```

### Point-in-time Recovery

```yaml
spec:
  clone:
    cluster: "source-cluster"
    timestamp: "2024-01-15T12:00:00Z"
```

## Monitoring

### Built-in Metrics

The operator includes PostgreSQL exporter for Prometheus:

- Connection metrics
- Query performance
- Resource usage
- Replication lag

### Health Checks

```bash
kubectl get postgresql -o wide
kubectl describe postgresql my-cluster
```

## Scaling

### Manual Scaling

```bash
./manage-postgres.sh scale my-postgres 3
```

### Resource Scaling

Update the cluster spec:

```yaml
spec:
  resources:
    requests:
      cpu: 2
      memory: 4Gi
    limits:
      cpu: 4
      memory: 8Gi
```

### Storage Scaling

Update the cluster spec:

```yaml
spec:
  volume:
    size: 50Gi  # Increases from current size
```

## Troubleshooting

### Common Issues

1. **Pod Stuck in Pending**
   - Check storage class availability
   - Verify node resources

2. **Connection Refused**
   - Check service endpoints
   - Verify user credentials
   - Check network policies

3. **Backup Failures**
   - Verify S3 credentials
   - Check backup job logs

### Debugging Commands

```bash
# Check operator logs
kubectl logs -n postgres-operator -l name=postgres-operator

# Check cluster events
kubectl describe postgresql my-cluster

# Check pod logs
kubectl logs my-cluster-0 -c postgres

# Check operator status
kubectl get postgresql my-cluster -o yaml
```

## Security

### SSL/TLS

Enabled by default with auto-generated certificates.

### Network Policies

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-network-policy
spec:
  podSelector:
    matchLabels:
      application: spilo
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: my-app
    ports:
    - protocol: TCP
      port: 5432
```

### RBAC

The operator creates minimal RBAC permissions for PostgreSQL pods.

## Best Practices

1. **Use teams** for organizing clusters
2. **Set resource limits** to prevent resource exhaustion
3. **Enable connection pooling** for high-traffic applications
4. **Use replicas** for read-heavy workloads
5. **Monitor** cluster health and performance
6. **Backup regularly** and test recovery procedures
7. **Use appropriate storage classes** for performance requirements
