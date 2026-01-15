#!/bin/bash
# Deploy Demo Applications Script
# Deploys demo applications to aws-us and local-cluster clusters

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[DEPLOY-APPS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[DEPLOY-APPS]${NC} $1"
}

error() {
    echo -e "${RED}[DEPLOY-APPS] ERROR:${NC} $1" >&2
    echo -e "${RED}[DEPLOY-APPS] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Detect kubectl command
if command -v oc >/dev/null 2>&1; then
    KUBECTL_CMD="oc"
elif command -v kubectl >/dev/null 2>&1; then
    KUBECTL_CMD="kubectl"
else
    error "Neither 'oc' nor 'kubectl' command found"
fi

DEMO_APPS_REPO="https://github.com/mfosterrox/demo-applications.git"
DEMO_APPS_DIR="/tmp/demo-applications"
MANIFESTS_DIR="$DEMO_APPS_DIR/k8s-deployment-manifests"

log "Deploying demo applications to aws-us and local-cluster clusters..."

# Clone or update the repository
if [ -d "$DEMO_APPS_DIR" ]; then
    log "Updating existing demo-applications repository..."
    if ! (cd "$DEMO_APPS_DIR" && git pull >/dev/null 2>&1); then
        warning "Failed to update repository, continuing with existing files"
    fi
else
    log "Cloning demo-applications repository..."
    if ! git clone "$DEMO_APPS_REPO" "$DEMO_APPS_DIR" >/dev/null 2>&1; then
        error "Failed to clone demo-applications repository"
    fi
fi

if [ ! -d "$MANIFESTS_DIR" ]; then
    error "Manifests directory not found: $MANIFESTS_DIR"
fi

# Function to deploy applications, skipping Skupper manifests if CRDs aren't available
deploy_applications() {
    local cluster=$1
    local context=$2
    
    log "Deploying applications to $cluster cluster..."
    if ! $KUBECTL_CMD config use-context "$context" >/dev/null 2>&1; then
        warning "Failed to switch to $context context, skipping deployment"
        return 1
    fi
    
    # Check if Skupper CRDs are available
    SKUPPER_AVAILABLE=false
    if $KUBECTL_CMD get crd sites.skupper.io >/dev/null 2>&1 && \
       $KUBECTL_CMD get crd serviceexports.skupper.io >/dev/null 2>&1; then
        SKUPPER_AVAILABLE=true
        log "Skupper CRDs detected, will deploy Skupper applications"
    else
        log "Skupper CRDs not found, skipping Skupper-related applications"
    fi
    
    # Deploy manifests, excluding Skupper directories if CRDs aren't available
    if [ "$SKUPPER_AVAILABLE" = "true" ]; then
        # Deploy all manifests including Skupper
        if $KUBECTL_CMD apply -R -f "$MANIFESTS_DIR" 2>&1; then
            log "✓ Applications deployed successfully to $cluster cluster"
            return 0
        else
            warning "Some resources failed to deploy to $cluster cluster"
            return 1
        fi
    else
        # Deploy all manifests except Skupper directories
        DEPLOY_ERRORS=0
        for dir in "$MANIFESTS_DIR"/*; do
            if [ -d "$dir" ]; then
                dirname=$(basename "$dir")
                # Skip Skupper directories
                if [[ "$dirname" == skupper* ]]; then
                    log "Skipping $dirname (Skupper CRDs not available)"
                    continue
                fi
                # Deploy this directory
                if ! $KUBECTL_CMD apply -R -f "$dir" 2>&1; then
                    warning "Failed to deploy some resources from $dirname"
                    DEPLOY_ERRORS=$((DEPLOY_ERRORS + 1))
                fi
            fi
        done
        
        if [ $DEPLOY_ERRORS -eq 0 ]; then
            log "✓ Applications deployed successfully to $cluster cluster (Skupper skipped)"
            return 0
        else
            warning "Some resources failed to deploy to $cluster cluster"
            return 1
        fi
    fi
}

# Deploy to both clusters sequentially
deploy_applications "aws-us" "aws-us"
deploy_applications "local-cluster" "local-cluster"

log "Demo applications deployment complete"
