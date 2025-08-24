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
    echo "The password generator job might still be running or failed"
    echo
    echo "Check job status:"
    echo "kubectl get jobs -n macos-timemachine"
    echo "kubectl logs -n macos-timemachine job/timemachine-password-generator"
    exit 1
fi

# Try to get credentials from the info secret first
if kubectl get secret timemachine-credentials-info -n macos-timemachine &>/dev/null; then
    echo "📱 Using generated connection details..."
    USERNAME=$(kubectl get secret timemachine-credentials-info -n macos-timemachine -o jsonpath='{.data.username}' | base64 -d)
    PASSWORD=$(kubectl get secret timemachine-credentials-info -n macos-timemachine -o jsonpath='{.data.password}' | base64 -d)
    SMB_URL=$(kubectl get secret timemachine-credentials-info -n macos-timemachine -o jsonpath='{.data.smb-url}' | base64 -d)
    FINDER_URL=$(kubectl get secret timemachine-credentials-info -n macos-timemachine -o jsonpath='{.data.finder-url}' | base64 -d)
    FULL_CONNECTION=$(kubectl get secret timemachine-credentials-info -n macos-timemachine -o jsonpath='{.data.connection-info}' | base64 -d)
else
    echo "📱 Using basic credentials..."
    # Fallback to basic credentials
    USERNAME=$(kubectl get secret timemachine-credentials -n macos-timemachine -o jsonpath='{.data.username}' | base64 -d)
    PASSWORD=$(kubectl get secret timemachine-credentials -n macos-timemachine -o jsonpath='{.data.password}' | base64 -d)
    SMB_URL="smb://192.168.11.2"
    FINDER_URL="smb://192.168.11.2"
    FULL_CONNECTION="smb://$USERNAME:$PASSWORD@192.168.11.2/TimeMachine"
fi

echo "🔐 Generated Secure Credentials:"
echo "├─ Username: $USERNAME"
echo "├─ Password: $PASSWORD"
echo "├─ Share:    TimeMachine"
echo "└─ Storage:  4TiB"
echo

echo "🍎 macOS Connection Methods:"
echo
echo "Method 1: Network Discovery (Recommended)"
echo "1. Open Finder"
echo "2. Look for your TimeMachine server in sidebar under Network"
echo "3. Connect with the credentials above"
echo
echo "Method 2: Direct IP Connection"
echo "1. Open Finder → Go → Connect to Server (⌘K)"
echo "2. Enter: smb://<NODE_IP>"
echo "3. Username: $USERNAME"
echo "4. Password: $PASSWORD"
echo "5. Select 'TimeMachine' share"
echo
echo "Method 3: Time Machine Setup"
echo "1. Connect using Method 1 or 2"
echo "2. Open Time Machine preferences"
echo "3. Select 'TimeMachine' as backup disk"
echo "4. Start your first backup!"
echo

echo "🔒 Security Notes:"
echo "• Password is randomly generated (24 characters)"
echo "• Stored securely in Kubernetes secrets"
echo "• Service discoverable via Bonjour/mDNS"
echo "• Network access restricted by NetworkPolicy"
