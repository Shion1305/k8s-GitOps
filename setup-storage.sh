#!/bin/bash

# Create storage directories on all nodes
NODES="instance-2024-1 shion-ubuntu-2505"

for node in $NODES; do
    echo "Setting up storage on $node..."
    kubectl debug node/$node -it --image=busybox -- sh -c "mkdir -p /host/var/local-storage && chmod 755 /host/var/local-storage"
done

echo "Storage setup complete!"
