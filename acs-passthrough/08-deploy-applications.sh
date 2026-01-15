#!/bin/bash
# Application Deployment Script
# Deploys applications to OpenShift cluster and runs security scans

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[APP-DEPLOY]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[APP-DEPLOY]${NC} $1"
}

error() {
    echo -e "${RED}[APP-DEPLOY] ERROR:${NC} $1" >&2
    echo -e "${RED}[APP-DEPLOY] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Set up script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
DEMO_LABEL="demo=roadshow"

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"
log "Prerequisites validated successfully"

# Clone demo apps repository
log "Cloning demo apps repository..."
if [ ! -d "demo-apps" ]; then
    if ! git clone -b acs-demo-apps https://github.com/SeanRickerd/demo-apps demo-apps; then
        error "Failed to clone demo-apps repository. Check network connectivity and repository access."
    fi
    log "✓ Demo apps repository cloned successfully"
else
    log "Demo apps repository already exists, skipping clone"
fi

# Set TUTORIAL_HOME environment variable
log "Setting TUTORIAL_HOME environment variable..."
TUTORIAL_HOME="$(pwd)/demo-apps"
if [ ! -d "$TUTORIAL_HOME" ]; then
    error "TUTORIAL_HOME directory does not exist: $TUTORIAL_HOME"
fi
sed -i '/^export TUTORIAL_HOME=/d' ~/.bashrc
echo "export TUTORIAL_HOME=\"$TUTORIAL_HOME\"" >> ~/.bashrc
export TUTORIAL_HOME="$TUTORIAL_HOME"
log "✓ TUTORIAL_HOME set to: $TUTORIAL_HOME"

# Deploy applications
log "Deploying applications from $TUTORIAL_HOME..."

# Deploy kubernetes-manifests
if [ -d "$TUTORIAL_HOME/kubernetes-manifests" ]; then
    log "Deploying kubernetes-manifests..."
    if ! oc apply -f "$TUTORIAL_HOME/kubernetes-manifests/" --recursive; then
        error "Failed to deploy kubernetes-manifests. Check manifests: ls -la $TUTORIAL_HOME/kubernetes-manifests/"
    fi
    log "✓ kubernetes-manifests deployed successfully"
else
    error "kubernetes-manifests directory not found at: $TUTORIAL_HOME/kubernetes-manifests"
fi

# Deploy skupper-demo
if [ -d "$TUTORIAL_HOME/skupper-demo" ]; then
    log "Deploying skupper-demo..."
    if ! oc apply -f "$TUTORIAL_HOME/skupper-demo/" --recursive; then
        error "Failed to deploy skupper-demo. Check manifests: ls -la $TUTORIAL_HOME/skupper-demo/"
    fi
    log "✓ skupper-demo deployed successfully"
else
    error "skupper-demo directory not found at: $TUTORIAL_HOME/skupper-demo"
fi

# Wait for deployments to be ready
log "Waiting for deployments to be ready..."

# Get all deployments with demo=roadshow label
log "Checking deployments with label $DEMO_LABEL..."
DEPLOYMENTS_OUTPUT=$(oc get deployments -l "$DEMO_LABEL" -A 2>&1)
if [ $? -ne 0 ]; then
    error "Failed to get deployments with label $DEMO_LABEL. Error: $DEPLOYMENTS_OUTPUT"
fi
if [ -z "$DEPLOYMENTS_OUTPUT" ] || echo "$DEPLOYMENTS_OUTPUT" | grep -q "No resources found"; then
    error "No deployments found with label $DEMO_LABEL. Check if applications were deployed correctly."
fi
echo "$DEPLOYMENTS_OUTPUT"

# Wait for each deployment to be available
log "Waiting for deployments to be available..."
NAMESPACES=$(oc get deployments -l "$DEMO_LABEL" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u)
if [ -z "$NAMESPACES" ]; then
    error "No namespaces found with deployments labeled $DEMO_LABEL"
fi

for namespace in $NAMESPACES; do
    log "Waiting for deployments in namespace: $namespace"
    
    # Get deployment names in this namespace
    deployments=$(oc get deployments -l "$DEMO_LABEL" -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    if [ -z "$deployments" ]; then
        error "No deployments found in namespace $namespace with label $DEMO_LABEL"
    fi
    
    for deployment in $deployments; do
        log "Waiting for deployment: $deployment in namespace: $namespace"
        if ! oc wait --for=condition=Available deployment/"$deployment" -n "$namespace" --timeout=300s; then
            DEPLOYMENT_STATUS=$(oc get deployment "$deployment" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' || echo "unknown")
            error "Deployment $deployment in namespace $namespace failed to become Available after 5 minutes. Status: $DEPLOYMENT_STATUS. Check: oc describe deployment $deployment -n $namespace"
        fi
        log "✓ Deployment $deployment in namespace $namespace is Available"
    done
done

# Verify deployments are running
log "Verifying deployments are running..."
if ! kubectl get deployments -l "$DEMO_LABEL" -A; then
    error "Failed to verify deployments. Check deployments: kubectl get deployments -l $DEMO_LABEL -A"
fi

# Check pod status
log "Checking pod status..."
PODS_OUTPUT=$(kubectl get pods -l "$DEMO_LABEL" -A)
if [ $? -ne 0 ]; then
    error "Failed to check pod status"
fi
echo "$PODS_OUTPUT"

# Verify all pods are running
NOT_RUNNING_PODS=$(echo "$PODS_OUTPUT" | grep -v "Running\|Completed\|NAME" | grep -v "^$" || true)
if [ -n "$NOT_RUNNING_PODS" ]; then
    warning "Some pods are not in Running or Completed state:"
    echo "$NOT_RUNNING_PODS"
fi

# Final status
log "Application deployment completed successfully!"
log "========================================================="
if ! kubectl get deployments -l "$DEMO_LABEL" -A; then
    error "Failed to retrieve final deployment status"
fi
log "========================================================="