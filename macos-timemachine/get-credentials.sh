#!/bin/bash
# Script to retrieve TimeMachine credentials

echo "=== TimeMachine Service Credentials ==="
echo

# Check if namespace exists
if ! kubectl get namespace macos-timemachine &>/dev/null; then
    echo "❌ Namespace 'macos-timemachine' not found"
    echo "Please deploy the TimeMachine service first"
    exit 1
fi

# Check if secret exists
if ! kubectl get secret timemachine-credentials -n macos-timemachine &>/dev/null; then
    echo "❌ Credentials secret not found"
    echo "The credential generator job might still be running or failed"
    echo
    echo "Check job status:"
    echo "kubectl get jobs -n macos-timemachine"
    echo "kubectl logs -n macos-timemachine job/timemachine-credential-generator"
    exit 1
fi

# Try to get credentials from the readable secret first
if kubectl get secret timemachine-credentials-readable -n macos-timemachine &>/dev/null; then
    echo "📱 Using pre-configured connection details..."
    USERNAME=$(kubectl get secret timemachine-credentials-readable -n macos-timemachine -o jsonpath='{.data.username}' | base64 -d)
    PASSWORD=$(kubectl get secret timemachine-credentials-readable -n macos-timemachine -o jsonpath='{.data.password}' | base64 -d)
    NODE_IP=$(kubectl get secret timemachine-credentials-readable -n macos-timemachine -o jsonpath='{.data.node-ip}' | base64 -d)
    SMB_URL=$(kubectl get secret timemachine-credentials-readable -n macos-timemachine -o jsonpath='{.data.smb-url}' | base64 -d)
    FULL_CONNECTION=$(kubectl get secret timemachine-credentials-readable -n macos-timemachine -o jsonpath='{.data.connection-info}' | base64 -d)
else
    echo "📱 Using basic credentials..."
    # Fallback to basic credentials
    USERNAME=$(kubectl get secret timemachine-credentials -n macos-timemachine -o jsonpath='{.data.username}' | base64 -d)
    PASSWORD=$(kubectl get secret timemachine-credentials -n macos-timemachine -o jsonpath='{.data.password}' | base64 -d)
    
    # Get node IP
    NODE_IP=$(kubectl get nodes -l kubernetes.io/hostname=shion-ubuntu-2505 -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    
    if [ -z "$NODE_IP" ]; then
        echo "⚠️  Could not determine node IP automatically"
        NODE_IP="<NODE_IP>"
    fi
    
    SMB_URL="smb://$NODE_IP:30445"
    FULL_CONNECTION="smb://timemachine:$PASSWORD@$NODE_IP:30445/TimeMachine"
fi

echo "📋 Connection Details:"
echo "├─ Username: $USERNAME"
echo "├─ Password: $PASSWORD"
echo "├─ SMB URL:  smb://$USERNAME:$PASSWORD@$NODE_IP:30445/TimeMachine"
echo "└─ Node IP:  $NODE_IP"
echo

echo "🍎 macOS Connection:"
echo "1. Open Finder → Go → Connect to Server (⌘K)"
echo "2. Enter: smb://$NODE_IP:30445"
echo "3. Username: $USERNAME"
echo "4. Password: $PASSWORD"
echo "5. Select 'TimeMachine' share"
echo "6. In Time Machine preferences, select the mounted share"
echo

echo "🔒 Security Notes:"
echo "• Password is randomly generated and stored securely in Kubernetes"
echo "• Service is accessible only from local network (192.168.0.0/16)"
echo "• Running exclusively on node: shion-ubuntu-2505"
