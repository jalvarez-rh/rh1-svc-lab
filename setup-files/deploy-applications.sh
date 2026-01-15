#!/bin/bash
# Deploy Hummingbird Images Script
# Deploys all hummingbird images from quay.io/organization/hummingbird to the cluster

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

# Check if oc is available
if ! command -v oc &>/dev/null; then
    error "OpenShift CLI (oc) command not found. Please install it."
fi

log "Using: oc"

# Check if we're connected to a cluster
if ! oc cluster-info &>/dev/null; then
    error "Not connected to a cluster. Please login first with: oc login"
fi

log "Connected to cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"

# List of hummingbird images to deploy
# Format: "image|namespace|app-name"
HUMMINGBIRD_IMAGES=(
    "quay.io/hummingbird/core-runtime:latest|default|core-runtime"
    "quay.io/hummingbird/postgresql:latest|default|hummingbird-postgresql"
    "quay.io/hummingbird/python:3.14|default|hummingbird-python"
    "quay.io/hummingbird/php:8|default|hummingbird-php"
)

log "Deploying ${#HUMMINGBIRD_IMAGES[@]} hummingbird image(s)..."

# Deploy each image
for image_spec in "${HUMMINGBIRD_IMAGES[@]}"; do
    IFS='|' read -r image namespace app_name <<< "$image_spec"
    
    log ""
    log "====================================="
    log "Deploying $image as app/$app_name (scaling to 1 replicas)"
    log "====================================="
    
    # Create namespace if specified and doesn't exist
    if [ -n "${namespace:-}" ] && [ "${namespace}" != "default" ]; then
        if ! oc get namespace "$namespace" &>/dev/null; then
            log "Creating namespace: $namespace"
            oc create namespace "$namespace"
        fi
        NAMESPACE_ARG="-n $namespace"
    else
        NAMESPACE_ARG=""
    fi
    
    # Deploy using oc new-app - avoid --dry-run=client issue by using --dry-run -o yaml | oc apply
    set +e
    DEPLOY_OUTPUT=$(oc new-app "$image" --name="$app_name" $NAMESPACE_ARG --dry-run -o yaml 2>&1)
    DEPLOY_EXIT=$?
    set -e
    
    if [ $DEPLOY_EXIT -eq 0 ]; then
        # Successfully generated YAML, apply it
        echo "$DEPLOY_OUTPUT" | oc apply -f -
        log "✓ Successfully deployed $app_name"
    else
        # Fallback: deploy directly without dry-run
        warning "Dry-run failed, deploying directly..."
        if oc new-app "$image" --name="$app_name" $NAMESPACE_ARG; then
            log "✓ Successfully deployed $app_name"
        else
            warning "Failed to deploy $app_name: $DEPLOY_OUTPUT"
            warning "Continuing with next image..."
            continue
        fi
    fi
    
    # Scale to 1 replica if deployment was created
    sleep 2
    if oc get deployment "$app_name" $NAMESPACE_ARG &>/dev/null 2>&1; then
        log "Scaling $app_name to 1 replica..."
        oc scale deployment "$app_name" --replicas=1 $NAMESPACE_ARG --timeout=30s || true
    elif oc get deploymentconfig "$app_name" $NAMESPACE_ARG &>/dev/null 2>&1; then
        log "Scaling deploymentconfig $app_name to 1 replica..."
        oc scale deploymentconfig "$app_name" --replicas=1 $NAMESPACE_ARG --timeout=30s || true
    fi
done

log ""
log "========================================================="
log "Deployment completed!"
log "========================================================="
log ""
log "To verify deployments, run:"
log "  oc get deployments --all-namespaces | grep hummingbird"
log "  oc get pods --all-namespaces | grep hummingbird"
log ""
