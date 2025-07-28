#!/bin/bash

# Node Storage Monitor Script
# This script monitors PV allocation per node and taints nodes when they exceed capacity

NODE_CAPACITY_GB=800
STORAGE_THRESHOLD_PERCENT=85  # Taint node when 85% full

# Function to calculate storage allocation per node
calculate_node_storage() {
    local node=$1
    local total_gb=0
    
    # Get PVs allocated to this node (both static and dynamic)
    echo "Calculating storage for node: $node"
    
    # Static PVs with node affinity
    local static_pvs=$(kubectl get pv -o json | jq -r ".items[] | select(.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0] == \"$node\") | .spec.capacity.storage")
    
    # Dynamic PVs from local-path provisioner
    local dynamic_pvs=$(kubectl get pv -o json | jq -r ".items[] | select(.metadata.annotations.\"local.path.provisioner/selected-node\" == \"$node\") | .spec.capacity.storage")
    
    # Convert and sum all storage
    for storage in $static_pvs $dynamic_pvs; do
        if [[ $storage =~ ^([0-9]+)Gi$ ]]; then
            gb=${BASH_REMATCH[1]}
            total_gb=$((total_gb + gb))
        fi
    done
    
    echo $total_gb
}

# Function to taint/untaint node based on storage usage
manage_node_taint() {
    local node=$1
    local used_gb=$2
    local threshold_gb=$((NODE_CAPACITY_GB * STORAGE_THRESHOLD_PERCENT / 100))
    
    echo "Node: $node, Used: ${used_gb}GB, Threshold: ${threshold_gb}GB"
    
if [[ $used_gb -gt $threshold_gb ]]; then
        echo "⚠️  Node $node exceeds storage threshold, adding taint..."
        kubectl taint node $node storage.capacity.cluster.local/full=true:NoSchedule --overwrite
    else
        echo "✅ Node $node within storage limits, removing taint if exists..."
        kubectl taint node $node storage.capacity.cluster.local/full- --ignore-not-found
    fi
}

# Main monitoring loop
main() {
    echo "🔍 Starting node storage monitoring..."
    
    # Get all nodes
    nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
    
    for node in $nodes; do
        used_storage=$(calculate_node_storage $node)
        manage_node_taint $node $used_storage
        echo "---"
    done
}

# Run the main function
main
