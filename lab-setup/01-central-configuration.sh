#!/bin/bash
# RHACS Central Route Configuration Script
# Configures Central CR with passthrough and reencrypt routes

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

# Find Central CR name
CENTRAL_NAME=$(oc get central -n "$CENTRAL_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$CENTRAL_NAME" ]; then
    error "Central CR not found in namespace $CENTRAL_NAMESPACE"
fi
log "✓ Found Central CR: $CENTRAL_NAME"

# Get cluster domain from existing route or ingress config
log ""
log "Detecting cluster domain..."
CLUSTER_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
if [ -z "$CLUSTER_DOMAIN" ]; then
    # Try to extract from existing route
    EXISTING_ROUTE_HOST=$(oc get route "$CENTRAL_ROUTE_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$EXISTING_ROUTE_HOST" ]; then
        # Extract domain from route host (e.g., apps.cluster-xxx.dynamic.redhatworkshops.io)
        CLUSTER_DOMAIN=$(echo "$EXISTING_ROUTE_HOST" | sed 's/^[^.]*\.//')
        log "✓ Extracted cluster domain from existing route: $CLUSTER_DOMAIN"
    else
        error "Could not determine cluster domain. Please ensure Central is installed or provide cluster domain."
    fi
else
    log "✓ Cluster domain: $CLUSTER_DOMAIN"
fi

# Construct route hosts
PASSTHROUGH_HOST="central-passthrough.${CLUSTER_DOMAIN}"
RECENCRYPT_HOST="central-stackrox.${CLUSTER_DOMAIN}"

log ""
log "Configuring Central CR with routes:"
log "  Passthrough route: $PASSTHROUGH_HOST"
log "  Reencrypt route: $RECENCRYPT_HOST"

# Check current Central CR route configuration
CURRENT_ROUTE_ENABLED=$(oc get central "$CENTRAL_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.central.exposure.route.enabled}' 2>/dev/null || echo "true")
CURRENT_ROUTE_HOST=$(oc get central "$CENTRAL_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.central.exposure.route.host}' 2>/dev/null || echo "")
CURRENT_RECENCRYPT_ENABLED=$(oc get central "$CENTRAL_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.central.exposure.route.reencrypt.enabled}' 2>/dev/null || echo "false")
CURRENT_RECENCRYPT_HOST=$(oc get central "$CENTRAL_NAME" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.central.exposure.route.reencrypt.host}' 2>/dev/null || echo "")

# Configure Central CR with both routes
log ""
log "Updating Central CR route configuration..."

# Use oc patch to update the route configuration
oc patch central "$CENTRAL_NAME" -n "$CENTRAL_NAMESPACE" --type merge -p "{
  \"spec\": {
    \"central\": {
      \"exposure\": {
        \"route\": {
          \"enabled\": true,
          \"host\": \"${PASSTHROUGH_HOST}\",
          \"reencrypt\": {
            \"enabled\": true,
            \"host\": \"${RECENCRYPT_HOST}\"
          }
        }
      }
    }
  }
}" || error "Failed to update Central CR route configuration"

log "✓ Central CR updated successfully"

# Wait for operator to reconcile
log ""
log "Waiting for operator to reconcile route configuration..."
sleep 15

# Verify routes were created
log ""
log "Verifying routes..."
PASSTHROUGH_ROUTE_EXISTS=$(oc get route -n "$CENTRAL_NAMESPACE" -o jsonpath="{.items[?(@.spec.host=='${PASSTHROUGH_HOST}')].metadata.name}" 2>/dev/null || echo "")
RECENCRYPT_ROUTE_EXISTS=$(oc get route -n "$CENTRAL_NAMESPACE" -o jsonpath="{.items[?(@.spec.host=='${RECENCRYPT_HOST}')].metadata.name}" 2>/dev/null || echo "")

if [ -n "$PASSTHROUGH_ROUTE_EXISTS" ]; then
    PASSTHROUGH_TERMINATION=$(oc get route "$PASSTHROUGH_ROUTE_EXISTS" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    log "✓ Passthrough route '$PASSTHROUGH_ROUTE_EXISTS' exists (termination: ${PASSTHROUGH_TERMINATION:-passthrough})"
else
    warning "Passthrough route not found yet (may need more time to reconcile)"
fi

if [ -n "$RECENCRYPT_ROUTE_EXISTS" ]; then
    RECENCRYPT_TERMINATION=$(oc get route "$RECENCRYPT_ROUTE_EXISTS" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    log "✓ Reencrypt route '$RECENCRYPT_ROUTE_EXISTS' exists (termination: ${RECENCRYPT_TERMINATION:-reencrypt})"
else
    warning "Reencrypt route not found yet (may need more time to reconcile)"
fi

# Final verification
log ""
log "========================================================="
log "RHACS Central Route Configuration"
log "========================================================="
log "Passthrough Route: https://${PASSTHROUGH_HOST}"
if [ -n "$RECENCRYPT_ROUTE_EXISTS" ]; then
    log "Reencrypt Route: https://${RECENCRYPT_HOST}"
fi
log "========================================================="
log ""
