#!/bin/bash

# PostgreSQL Operator Management Script

set -e

NAMESPACE="postgres-clusters"

function usage() {
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  list                  - List all PostgreSQL clusters"
    echo "  status <cluster>      - Show cluster status"
    echo "  connect <cluster>     - Get connection info for cluster"
    echo "  users <cluster>       - List users and their credentials"
    echo "  logs <cluster>        - Show cluster logs"
    echo "  scale <cluster> <n>   - Scale cluster to n instances"
    echo "  backup <cluster>      - Trigger manual backup"
    echo ""
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 status dev-postgres"
    echo "  $0 connect dev-postgres"
    echo "  $0 scale prod-postgres 5"
}

function list_clusters() {
    echo "📊 PostgreSQL Clusters:"
    kubectl get postgresql -n $NAMESPACE -o custom-columns="NAME:.metadata.name,TEAM:.spec.teamId,INSTANCES:.spec.numberOfInstances,VERSION:.spec.postgresql.version,STATUS:.status.PostgreSQLStatus" 2>/dev/null || echo "No clusters found"
}

function cluster_status() {
    local cluster=$1
    if [[ -z "$cluster" ]]; then
        echo "❌ Cluster name required"
        exit 1
    fi
    
    echo "🔍 Status for cluster: $cluster"
    kubectl get postgresql $cluster -n $NAMESPACE -o yaml
    echo ""
    echo "📦 Pods:"
    kubectl get pods -n $NAMESPACE -l cluster-name=$cluster
    echo ""
    echo "💾 PVCs:"
    kubectl get pvc -n $NAMESPACE -l cluster-name=$cluster
}

function connect_info() {
    local cluster=$1
    if [[ -z "$cluster" ]]; then
        echo "❌ Cluster name required"
        exit 1
    fi
    
    echo "🔗 Connection information for cluster: $cluster"
    echo ""
    echo "📍 Service endpoints:"
    kubectl get svc -n $NAMESPACE -l cluster-name=$cluster
    echo ""
    echo "🔑 User credentials (secrets):"
    kubectl get secrets -n $NAMESPACE -l cluster-name=$cluster | grep -E "(username|password)"
    echo ""
    echo "💡 To get a specific user's password:"
    echo "kubectl get secret <cluster>.<username> -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
    echo ""
    echo "📝 Connection string example:"
    echo "psql -h $cluster.$NAMESPACE.svc.cluster.local -U <username> -d <database>"
}

function list_users() {
    local cluster=$1
    if [[ -z "$cluster" ]]; then
        echo "❌ Cluster name required"
        exit 1
    fi
    
    echo "👥 Users for cluster: $cluster"
    kubectl get secrets -n $NAMESPACE -l cluster-name=$cluster | grep -v postgres-exporter | grep -v "^NAME"
    echo ""
    echo "💡 To get credentials:"
    echo "kubectl get secret $cluster.<username> -n $NAMESPACE -o jsonpath='{.data.username}' | base64 -d"
    echo "kubectl get secret $cluster.<username> -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
}

function show_logs() {
    local cluster=$1
    if [[ -z "$cluster" ]]; then
        echo "❌ Cluster name required"
        exit 1
    fi
    
    echo "📋 Logs for cluster: $cluster"
    kubectl logs -n $NAMESPACE -l cluster-name=$cluster -c postgres --tail=50
}

function scale_cluster() {
    local cluster=$1
    local instances=$2
    
    if [[ -z "$cluster" || -z "$instances" ]]; then
        echo "❌ Cluster name and instance count required"
        exit 1
    fi
    
    echo "⚙️  Scaling cluster $cluster to $instances instances..."
    kubectl patch postgresql $cluster -n $NAMESPACE --type='merge' -p="{\"spec\":{\"numberOfInstances\":$instances}}"
    echo "✅ Scaling initiated. Check status with: $0 status $cluster"
}

function trigger_backup() {
    local cluster=$1
    if [[ -z "$cluster" ]]; then
        echo "❌ Cluster name required"
        exit 1
    fi
    
    echo "💾 Triggering backup for cluster: $cluster"
    kubectl annotate postgresql $cluster -n $NAMESPACE zalando.org/manual-backup="$(date +%Y%m%d-%H%M%S)"
    echo "✅ Backup initiated. Check logs for progress."
}

# Main script logic
case "$1" in
    list)
        list_clusters
        ;;
    status)
        cluster_status "$2"
        ;;
    connect)
        connect_info "$2"
        ;;
    users)
        list_users "$2"
        ;;
    logs)
        show_logs "$2"
        ;;
    scale)
        scale_cluster "$2" "$3"
        ;;
    backup)
        trigger_backup "$2"
        ;;
    *)
        usage
        exit 1
        ;;
esac
