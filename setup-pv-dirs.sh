#!/bin/bash

echo "Creating PostgreSQL storage directory on instance-2024-1..."
kubectl debug node/instance-2024-1 -it --image=busybox -- sh -c "mkdir -p /host/var/local-storage/postgres-1 && chmod 755 /host/var/local-storage/postgres-1"

echo "Creating PostgreSQL storage directory on shion-ubuntu-2505..."
kubectl debug node/shion-ubuntu-2505 -it --image=busybox -- sh -c "mkdir -p /host/var/local-storage/postgres-2 && chmod 755 /host/var/local-storage/postgres-2"

echo "Creating Airbyte storage directory on instance-2024-1..."
kubectl debug node/instance-2024-1 -it --image=busybox -- sh -c "mkdir -p /host/var/local-storage/airbyte-1 && chmod 755 /host/var/local-storage/airbyte-1"

echo "Creating Airbyte storage directory on shion-ubuntu-2505..."
kubectl debug node/shion-ubuntu-2505 -it --image=busybox -- sh -c "mkdir -p /host/var/local-storage/airbyte-2 && chmod 755 /host/var/local-storage/airbyte-2"

echo "PV directories setup complete!"
