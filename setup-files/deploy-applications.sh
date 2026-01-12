#!/bin/bash
# Deploy All Demo Applications Script
# Deploys all applications from the demo-applications repository

set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[DEPLOY]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[DEPLOY]${NC} $1"
}

error() {
    echo -e "${RED}[DEPLOY] ERROR:${NC} $1" >&2
    exit 1
}

# Check if oc/kubectl is available
if command -v oc &>/dev/null; then
    KUBECTL_CMD="oc"
elif command -v kubectl &>/dev/null; then
    KUBECTL_CMD="kubectl"
else
    error "Neither 'oc' nor 'kubectl' command found. Please install one of them."
fi

log "Using: $KUBECTL_CMD"

# Check if we're connected to a cluster
if ! $KUBECTL_CMD cluster-info &>/dev/null; then
    error "Not connected to a cluster. Please login first."
fi

# Set demo-applications directory
DEMO_APPS_DIR="${DEMO_APPS_DIR:-$HOME/demo-applications}"
MANIFESTS_DIR="$DEMO_APPS_DIR/k8s-deployment-manifests"

if [ ! -d "$MANIFESTS_DIR" ]; then
    error "Demo applications directory not found at: $MANIFESTS_DIR"
    error "Please set DEMO_APPS_DIR environment variable or ensure demo-applications is cloned to $HOME/demo-applications"
fi

log "Deploying applications from: $MANIFESTS_DIR"

# Deploy namespaces first
log "Deploying namespaces..."
if [ -d "$MANIFESTS_DIR/-namespaces" ]; then
    $KUBECTL_CMD apply -f "$MANIFESTS_DIR/-namespaces/"
    log "✓ Namespaces deployed"
else
    warning "Namespaces directory not found, skipping..."
fi

# Deploy all application manifests recursively
log "Deploying application manifests..."
$KUBECTL_CMD apply -R -f "$MANIFESTS_DIR/"
log "✓ Applications deployed"

log ""
log "========================================================="
log "Deployment completed successfully!"
log "========================================================="
log ""
log "To verify deployments, run:"
log "  $KUBECTL_CMD get pods --all-namespaces | grep -E '(apache-struts|dvwa|juice-shop|log4shell|nodejs-goof|patient-portal|unprotected-api|web-ctf|webgoat)'"
log ""
