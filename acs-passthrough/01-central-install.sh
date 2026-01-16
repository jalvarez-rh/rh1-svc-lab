#!/bin/bash
# RHACS Central Passthrough Route Configuration Script
# Ensures Central route uses passthrough termination (TLS terminated at backend service)

# Exit immediately on error, show exact error message
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

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Detect Central namespace and resource
log ""
log "Detecting Central installation..."

# Try stackrox namespace first (as mentioned by user)
CENTRAL_NAMESPACE=""
CENTRAL_NAME=""
CENTRAL_RESOURCE=""

if oc get namespace stackrox &>/dev/null; then
    CENTRAL_NAMESPACE="stackrox"
    log "Found namespace: stackrox"
    
    # Find Central CR in stackrox namespace
    CENTRAL_RESOURCE=$(oc get central -n stackrox -o name 2>/dev/null | head -1 || echo "")
    if [ -n "$CENTRAL_RESOURCE" ]; then
        # Extract just the resource name (everything after the last /)
        CENTRAL_NAME=$(echo "$CENTRAL_RESOURCE" | sed 's|.*/||')
        log "Found Central CR: $CENTRAL_NAME in namespace stackrox"
    fi
fi

# If not found, search all namespaces
if [ -z "$CENTRAL_RESOURCE" ]; then
    log "Searching for Central CR in all namespaces..."
    CENTRAL_RESOURCE=$(oc get central --all-namespaces -o name 2>/dev/null | head -1 || echo "")
    if [ -n "$CENTRAL_RESOURCE" ]; then
        # Format is: namespace/kind.apiVersion/name or namespace/kind/name
        # Extract namespace (first part before /)
        CENTRAL_NAMESPACE=$(echo "$CENTRAL_RESOURCE" | cut -d'/' -f1)
        # Extract resource name (last part after final /)
        CENTRAL_NAME=$(echo "$CENTRAL_RESOURCE" | sed 's|.*/||')
        log "Found Central CR: $CENTRAL_NAME in namespace $CENTRAL_NAMESPACE"
    fi
fi

if [ -z "$CENTRAL_RESOURCE" ]; then
    error "Central CR not found. Please ensure RHACS Central is installed."
fi

log "✓ Using Central CR: $CENTRAL_NAME in namespace: $CENTRAL_NAMESPACE"

# Check current route configuration
log ""
log "Checking current route configuration..."

# Find Central route
CENTRAL_ROUTE_NAME=$(oc get route -n "$CENTRAL_NAMESPACE" -o name 2>/dev/null | grep -i central | head -1 | sed 's|route.route.openshift.io/||' || echo "")
if [ -z "$CENTRAL_ROUTE_NAME" ]; then
    # Try common route names
    for route_name in central central-stackrox; do
        if oc get route "$route_name" -n "$CENTRAL_NAMESPACE" &>/dev/null; then
            CENTRAL_ROUTE_NAME="$route_name"
            break
        fi
    done
fi

if [ -z "$CENTRAL_ROUTE_NAME" ]; then
    error "Central route not found in namespace $CENTRAL_NAMESPACE"
fi

log "Found route: $CENTRAL_ROUTE_NAME"

# Check current termination type
CURRENT_TERMINATION=$(oc get route "$CENTRAL_ROUTE_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
CENTRAL_ROUTE_HOST=$(oc get route "$CENTRAL_ROUTE_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

log "Current route termination: ${CURRENT_TERMINATION:-edge}"

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
    
    # Ensure route is enabled in Central CR
    EXISTING_ROUTE_ENABLED=$(oc get central "$CENTRAL_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.central.exposure.route.enabled}' 2>/dev/null || echo "")
    if [ "$EXISTING_ROUTE_ENABLED" != "true" ]; then
        log "Enabling route in Central CR..."
        oc patch central "$CENTRAL_NAME" -n "$CENTRAL_NAMESPACE" --type merge -p '{"spec":{"central":{"exposure":{"route":{"enabled":true}}}}}' || error "Failed to enable route"
        log "✓ Route enabled"
    fi
    
    # Wait a moment for operator to reconcile
    log "Waiting for operator to reconcile route configuration..."
    sleep 10
    
    # Verify route is now passthrough
    UPDATED_TERMINATION=$(oc get route "$CENTRAL_ROUTE_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    
    if [ "$UPDATED_TERMINATION" = "passthrough" ]; then
        log "✓ Route is now configured as passthrough"
    else
        warning "Route termination is still: ${UPDATED_TERMINATION:-edge}"
        warning "Operator may need more time to reconcile. Current route spec:"
        oc get route "$CENTRAL_ROUTE_NAME" -n "$CENTRAL_NAMESPACE" -o yaml | grep -A 5 "tls:" || true
    fi
else
    log "✓ Route is already configured as passthrough"
fi

# Final verification
log ""
log "========================================================="
log "RHACS Central Route Configuration"
log "========================================================="
log "Namespace: $CENTRAL_NAMESPACE"
log "Central Resource: $CENTRAL_NAME"
log "Route Name: $CENTRAL_ROUTE_NAME"
FINAL_TERMINATION=$(oc get route "$CENTRAL_ROUTE_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
log "Route Termination: ${FINAL_TERMINATION:-passthrough}"
if [ -n "$CENTRAL_ROUTE_HOST" ]; then
    log "Central URL: https://$CENTRAL_ROUTE_HOST"
fi
log "========================================================="
log ""
