#!/bin/bash
# Application Deployment Script
# Deploys applications to OpenShift cluster and runs security scans

# Don't exit on error - just deploy and continue
set -uo pipefail

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

# No error trap - just continue on errors

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
    oc apply -f "$TUTORIAL_HOME/kubernetes-manifests/" --recursive || warning "Some resources in kubernetes-manifests may have failed to apply"
    log "✓ kubernetes-manifests deployment attempted"
else
    warning "kubernetes-manifests directory not found at: $TUTORIAL_HOME/kubernetes-manifests"
fi

# Deploy skupper-demo
if [ -d "$TUTORIAL_HOME/skupper-demo" ]; then
    log "Deploying skupper-demo..."
    oc apply -f "$TUTORIAL_HOME/skupper-demo/" --recursive || warning "Some resources in skupper-demo may have failed to apply"
    log "✓ skupper-demo deployment attempted"
else
    warning "skupper-demo directory not found at: $TUTORIAL_HOME/skupper-demo"
fi

# Deployment complete - applications will start in the background
log ""
log "Application deployment completed!"
log "Applications have been deployed and will start in the background."
log "You can check their status with: oc get pods -A"
log ""