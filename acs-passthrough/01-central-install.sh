#!/bin/bash
# RHACS Central Passthrough Route Configuration Script
# Ensures Central route uses passthrough termination (TLS terminated at backend service)

# Exit immediately on error, show error message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RHACS-CENTRAL]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-CENTRAL]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-CENTRAL] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-CENTRAL] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Fixed values based on environment
CENTRAL_NAMESPACE="stackrox"
CENTRAL_ROUTE_NAME="central"

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Check current route termination
log ""
log "Checking route termination..."
CURRENT_TERMINATION=$(oc get route "$CENTRAL_ROUTE_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
CENTRAL_ROUTE_HOST=$(oc get route "$CENTRAL_ROUTE_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

log "Current route termination: ${CURRENT_TERMINATION:-edge}"

# Find Central CR name
CENTRAL_NAME=$(oc get central -n "$CENTRAL_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$CENTRAL_NAME" ]; then
    error "Central CR not found in namespace $CENTRAL_NAMESPACE"
fi

# Check Central CR for reencrypt configuration
EXISTING_RECENCRYPT=$(oc get central "$CENTRAL_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.central.exposure.route.reencrypt.enabled}' 2>/dev/null || echo "")

# Configure passthrough if needed
if [ "$CURRENT_TERMINATION" != "passthrough" ] || [ "$EXISTING_RECENCRYPT" = "true" ]; then
    log ""
    log "Configuring route for passthrough termination..."
    
    # Remove reencrypt from Central CR if it exists
    if [ "$EXISTING_RECENCRYPT" = "true" ]; then
        log "Removing reencrypt configuration from Central CR..."
        oc patch central "$CENTRAL_NAME" -n "$CENTRAL_NAMESPACE" --type json -p '[{"op": "remove", "path": "/spec/central/exposure/route/reencrypt"}]' || error "Failed to remove reencrypt configuration"
        log "✓ Reencrypt configuration removed"
    fi
    
    # Wait for operator to reconcile
    log "Waiting for operator to reconcile route configuration..."
    sleep 10
    
    # Verify route is now passthrough
    UPDATED_TERMINATION=$(oc get route "$CENTRAL_ROUTE_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    
    if [ "$UPDATED_TERMINATION" = "passthrough" ]; then
        log "✓ Route is now configured as passthrough"
    else
        warning "Route termination is still: ${UPDATED_TERMINATION:-edge}"
        warning "Operator may need more time to reconcile"
    fi
else
    log "✓ Route is already configured as passthrough"
fi

# Final verification
log ""
log "========================================================="
log "RHACS Central Route Configuration"
log "========================================================="
FINAL_TERMINATION=$(oc get route "$CENTRAL_ROUTE_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
log "Route Termination: ${FINAL_TERMINATION:-passthrough}"
if [ -n "$CENTRAL_ROUTE_HOST" ]; then
    log "Central URL: https://$CENTRAL_ROUTE_HOST"
fi
log "========================================================="
log ""


# Scale down operator to stop reconciliation
oc scale deployment/central -n stackrox --replicas=0
sleep 60  # wait for it to stop

# Edit route to passthrough
oc -n stackrox edit route central 