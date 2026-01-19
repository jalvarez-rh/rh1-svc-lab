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

# First, disable routes in Central CR to clean up existing routes
log ""
log "Disabling routes in Central CR to clean up existing routes..."
oc patch central "$CENTRAL_NAME" -n "$CENTRAL_NAMESPACE" --type merge -p "{
  \"spec\": {
    \"central\": {
      \"exposure\": {
        \"route\": {
          \"enabled\": false
        }
      }
    }
  }
}" || warning "Failed to disable routes in Central CR"

# Wait for operator to reconcile and delete routes
log "Waiting for operator to remove existing routes..."
sleep 15

# Delete any remaining routes manually
log "Deleting existing routes manually..."
oc delete route central -n "$CENTRAL_NAMESPACE" 2>/dev/null || true
oc delete route central-reencrypt -n "$CENTRAL_NAMESPACE" 2>/dev/null || true
oc delete route central-mtls -n "$CENTRAL_NAMESPACE" 2>/dev/null || true
sleep 5
log "✓ Cleaned up existing routes"

# Configure Central CR with passthrough route first
log ""
log "Configuring Central CR with passthrough route..."
oc patch central "$CENTRAL_NAME" -n "$CENTRAL_NAMESPACE" --type merge -p "{
  \"spec\": {
    \"central\": {
      \"exposure\": {
        \"route\": {
          \"enabled\": true,
          \"host\": \"${PASSTHROUGH_HOST}\",
          \"reencrypt\": {
            \"enabled\": false
          }
        }
      }
    }
  }
}" || error "Failed to update Central CR with passthrough route"

log "✓ Central CR configured with passthrough route"

# Wait for operator to create the passthrough route
log ""
log "Waiting for operator to create passthrough route..."
sleep 20

# Verify and fix the passthrough route termination
if oc get route central -n "$CENTRAL_NAMESPACE" >/dev/null 2>&1; then
    CURRENT_HOST=$(oc get route central -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    CURRENT_TERMINATION=$(oc get route central -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    
    if [ "$CURRENT_HOST" = "$PASSTHROUGH_HOST" ]; then
        if [ "$CURRENT_TERMINATION" != "passthrough" ]; then
            log "Patching central route to use passthrough termination (current: ${CURRENT_TERMINATION})..."
            oc patch route central -n "$CENTRAL_NAMESPACE" --type merge -p "{
              \"spec\": {
                \"tls\": {
                  \"termination\": \"passthrough\",
                  \"insecureEdgeTerminationPolicy\": \"Redirect\"
                }
              }
            }" || warning "Failed to patch central route termination"
            log "✓ Central route patched to passthrough"
        else
            log "✓ Central route already has passthrough termination"
        fi
    else
        warning "Central route host mismatch: expected ${PASSTHROUGH_HOST}, got ${CURRENT_HOST}"
        # Fix the host
        log "Fixing central route host to passthrough..."
        oc patch route central -n "$CENTRAL_NAMESPACE" --type merge -p "{
          \"spec\": {
            \"host\": \"${PASSTHROUGH_HOST}\",
            \"tls\": {
              \"termination\": \"passthrough\",
              \"insecureEdgeTerminationPolicy\": \"Redirect\"
            }
          }
        }" || warning "Failed to fix central route host"
        sleep 5
    fi
    
    # Ensure Central CR doesn't have reencrypt enabled (double-check)
    log "Ensuring Central CR doesn't have reencrypt enabled..."
    oc patch central "$CENTRAL_NAME" -n "$CENTRAL_NAMESPACE" --type merge -p "{
      \"spec\": {
        \"central\": {
          \"exposure\": {
            \"route\": {
              \"enabled\": true,
              \"host\": \"${PASSTHROUGH_HOST}\",
              \"reencrypt\": {
                \"enabled\": false
              }
            }
          }
        }
      }
    }" || warning "Failed to ensure reencrypt is disabled in Central CR"
    log "✓ Verified Central CR has reencrypt disabled"
    
    # Wait a bit to ensure operator has reconciled
    sleep 10
    
    # Re-verify the central route host hasn't changed
    VERIFIED_HOST=$(oc get route central -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ "$VERIFIED_HOST" != "$PASSTHROUGH_HOST" ]; then
        error "Central route host changed to ${VERIFIED_HOST} after ensuring reencrypt is disabled. Cannot proceed with reencrypt route creation."
    fi
    log "✓ Verified central route still has passthrough host: ${VERIFIED_HOST}"
else
    warning "Central route not found after configuration"
fi

# Don't enable reencrypt in Central CR - it causes the operator to change the central route host
# Instead, create the reencrypt route manually to avoid conflicts
log ""
log "Creating reencrypt route manually (not via Central CR to avoid host conflicts)..."

# First, verify the central route still has the passthrough host
CENTRAL_ROUTE_HOST=$(oc get route central -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ "$CENTRAL_ROUTE_HOST" != "$PASSTHROUGH_HOST" ]; then
    warning "Central route host changed to ${CENTRAL_ROUTE_HOST}, expected ${PASSTHROUGH_HOST}"
    log "Fixing central route host back to passthrough..."
    oc patch route central -n "$CENTRAL_NAMESPACE" --type merge -p "{
      \"spec\": {
        \"host\": \"${PASSTHROUGH_HOST}\"
      }
    }" || warning "Failed to fix central route host"
    sleep 5
fi

# Delete any existing central-reencrypt route that might have wrong host
if oc get route central-reencrypt -n "$CENTRAL_NAMESPACE" >/dev/null 2>&1; then
    EXISTING_RECENCRYPT_HOST=$(oc get route central-reencrypt -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ "$EXISTING_RECENCRYPT_HOST" != "$RECENCRYPT_HOST" ]; then
        log "Deleting existing central-reencrypt route with wrong host (${EXISTING_RECENCRYPT_HOST})..."
        oc delete route central-reencrypt -n "$CENTRAL_NAMESPACE" 2>/dev/null || true
        sleep 5
    fi
fi

# Create reencrypt route manually
if ! oc get route central-reencrypt -n "$CENTRAL_NAMESPACE" >/dev/null 2>&1; then
    log "Creating central-reencrypt route with host ${RECENCRYPT_HOST}..."
    oc create route reencrypt central-reencrypt \
        --service=central \
        --port=central \
        --hostname="${RECENCRYPT_HOST}" \
        --insecure-policy=Redirect \
        -n "$CENTRAL_NAMESPACE" 2>/dev/null || error "Failed to create central-reencrypt route"
    log "✓ Central-reencrypt route created"
    
    # Wait for route to be admitted
    sleep 5
    
    # Verify the route was created correctly
    CREATED_HOST=$(oc get route central-reencrypt -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    CREATED_TERMINATION=$(oc get route central-reencrypt -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    
    if [ "$CREATED_HOST" = "$RECENCRYPT_HOST" ] && [ "$CREATED_TERMINATION" = "reencrypt" ]; then
        log "✓ Central-reencrypt route created successfully with correct host and termination"
    else
        warning "Central-reencrypt route created but verification failed: host=${CREATED_HOST}, termination=${CREATED_TERMINATION}"
    fi
else
    log "✓ Central-reencrypt route already exists"
    CURRENT_HOST=$(oc get route central-reencrypt -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    CURRENT_TERMINATION=$(oc get route central-reencrypt -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    
    if [ "$CURRENT_HOST" != "$RECENCRYPT_HOST" ] || [ "$CURRENT_TERMINATION" != "reencrypt" ]; then
        log "Patching central-reencrypt route..."
        oc patch route central-reencrypt -n "$CENTRAL_NAMESPACE" --type merge -p "{
          \"spec\": {
            \"host\": \"${RECENCRYPT_HOST}\",
            \"tls\": {
              \"termination\": \"reencrypt\",
              \"insecureEdgeTerminationPolicy\": \"Redirect\"
            }
          }
        }" || warning "Failed to patch central-reencrypt route"
        log "✓ Central-reencrypt route patched"
    fi
fi

# Wait a bit more for routes to stabilize
sleep 10

# Verify routes were created
log ""
log "Verifying routes..."
PASSTHROUGH_ROUTE_EXISTS=$(oc get route -n "$CENTRAL_NAMESPACE" -o jsonpath="{.items[?(@.spec.host=='${PASSTHROUGH_HOST}')].metadata.name}" 2>/dev/null || echo "")
RECENCRYPT_ROUTE_EXISTS=$(oc get route -n "$CENTRAL_NAMESPACE" -o jsonpath="{.items[?(@.spec.host=='${RECENCRYPT_HOST}')].metadata.name}" 2>/dev/null || echo "")

if [ -n "$PASSTHROUGH_ROUTE_EXISTS" ]; then
    PASSTHROUGH_TERMINATION=$(oc get route "$PASSTHROUGH_ROUTE_EXISTS" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    if [ "$PASSTHROUGH_TERMINATION" = "passthrough" ]; then
        log "✓ Passthrough route '$PASSTHROUGH_ROUTE_EXISTS' exists with correct termination: ${PASSTHROUGH_TERMINATION}"
    else
        warning "Passthrough route '$PASSTHROUGH_ROUTE_EXISTS' exists but has wrong termination: ${PASSTHROUGH_TERMINATION} (expected: passthrough)"
    fi
else
    warning "Passthrough route not found yet (may need more time to reconcile)"
fi

if [ -n "$RECENCRYPT_ROUTE_EXISTS" ]; then
    RECENCRYPT_TERMINATION=$(oc get route "$RECENCRYPT_ROUTE_EXISTS" -n "$CENTRAL_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    if [ "$RECENCRYPT_TERMINATION" = "reencrypt" ]; then
        log "✓ Reencrypt route '$RECENCRYPT_ROUTE_EXISTS' exists with correct termination: ${RECENCRYPT_TERMINATION}"
    else
        warning "Reencrypt route '$RECENCRYPT_ROUTE_EXISTS' exists but has wrong termination: ${RECENCRYPT_TERMINATION} (expected: reencrypt)"
    fi
else
    warning "Reencrypt route not found yet (may need more time to reconcile)"
fi

# Show all routes for debugging
log ""
log "Current routes in namespace $CENTRAL_NAMESPACE:"
oc get routes -n "$CENTRAL_NAMESPACE" -o custom-columns=NAME:.metadata.name,HOST:.spec.host,TERMINATION:.spec.tls.termination 2>/dev/null || true

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
