#!/bin/bash
# RHACS Central Installation Script (Passthrough Route)
# Creates Central custom resource to deploy RHACS Central with passthrough route
# Passthrough routes terminate TLS at the backend service (not at the router)

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

log "Prerequisites validated successfully"

# RHACS operator namespace (where Central will be installed)
RHACS_OPERATOR_NAMESPACE="rhacs-operator"

# Ensure namespace exists
log "Ensuring namespace '$RHACS_OPERATOR_NAMESPACE' exists..."
if ! oc get namespace "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    error "Namespace '$RHACS_OPERATOR_NAMESPACE' does not exist. Please run the subscription install script first."
fi
log "✓ Namespace '$RHACS_OPERATOR_NAMESPACE' exists"

# Verify RHACS operator is installed
log ""
log "Verifying RHACS operator is installed..."
CSV_NAME=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Advanced Cluster Security for Kubernetes")].metadata.name}' 2>/dev/null || echo "")
if [ -z "$CSV_NAME" ]; then
    CSV_NAME=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o name 2>/dev/null | grep rhacs-operator | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
fi

if [ -z "$CSV_NAME" ]; then
    error "RHACS operator CSV not found. Please install the operator subscription first."
fi

CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "$CSV_PHASE" != "Succeeded" ]; then
    warning "RHACS operator CSV is not in Succeeded phase (current: $CSV_PHASE)"
    warning "Central installation may fail. Please wait for operator to be ready."
else
    log "✓ RHACS operator is ready (CSV: $CSV_NAME)"
fi

# Central resource name
CENTRAL_NAME="rhacs-central-services"

# Check if Central already exists
log ""
log "Checking if Central resource already exists..."
if oc get central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    log "Central resource '$CENTRAL_NAME' already exists"
    
    # Check if it's using reencrypt and patch to passthrough
    EXISTING_RECENCRYPT=$(oc get central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.central.exposure.route.reencrypt.enabled}' 2>/dev/null || echo "")
    
    if [ "$EXISTING_RECENCRYPT" = "true" ]; then
        log "Central is currently using reencrypt route, changing to passthrough..."
        
        # Patch Central to remove reencrypt (this enables passthrough)
        oc patch central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" --type json -p '[{"op": "remove", "path": "/spec/central/exposure/route/reencrypt"}]' || error "Failed to remove reencrypt configuration"
        log "✓ Central patched to use passthrough route"
    else
        log "✓ Central is already configured with passthrough route (or no reencrypt specified)"
    fi
    
    # Ensure route is enabled
    EXISTING_ROUTE_ENABLED=$(oc get central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.central.exposure.route.enabled}' 2>/dev/null || echo "")
    if [ "$EXISTING_ROUTE_ENABLED" != "true" ]; then
        log "Enabling route..."
        oc patch central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" --type merge -p '{"spec":{"central":{"exposure":{"route":{"enabled":true}}}}}' || error "Failed to enable route"
        log "✓ Route enabled"
    fi
    
    # Check Central status
    CENTRAL_STATUS=$(oc get central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
    if [ "$CENTRAL_STATUS" = "True" ]; then
        log "✓ Central is Available"
    else
        log "Central status: $CENTRAL_STATUS (may still be deploying)"
    fi
else
    log "Creating Central resource with passthrough route..."
    
    # Get Central DNS name from console route (if available)
    CENTRAL_DNS_NAME=""
    CONSOLE_ROUTE=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$CONSOLE_ROUTE" ]; then
        # Extract domain from console route (e.g., console.apps.cluster-xxx.example.com -> apps.cluster-xxx.example.com)
        DOMAIN=$(echo "$CONSOLE_ROUTE" | sed 's/^[^.]*\.//')
        CENTRAL_DNS_NAME="central.${DOMAIN}"
        log "Using DNS name: $CENTRAL_DNS_NAME"
    fi
    
    # Build Central CR YAML with passthrough route (no reencrypt section)
    CENTRAL_YAML="apiVersion: platform.stackrox.io/v1alpha1
kind: Central
metadata:
  name: $CENTRAL_NAME
  namespace: $RHACS_OPERATOR_NAMESPACE
spec:
  central:
    exposure:
      route:
        enabled: true"
    
    # Add hostname if we have the DNS name
    if [ -n "$CENTRAL_DNS_NAME" ]; then
        CENTRAL_YAML="${CENTRAL_YAML}
        host: $CENTRAL_DNS_NAME"
    fi
    
    # Note: We do NOT add reencrypt section - this makes it use passthrough by default
    
    # Apply the Central resource
    echo "$CENTRAL_YAML" | oc apply -f - || error "Failed to create Central resource"
    log "✓ Central resource created with passthrough route"
fi

# Wait for Central deployment to be ready
log ""
log "Waiting for Central deployment to be ready..."
MAX_WAIT=600
WAIT_COUNT=0
CENTRAL_READY=false

# Wait for deployment to exist first
log "Waiting for Central deployment to be created..."
DEPLOYMENT_WAIT=60
DEPLOYMENT_COUNT=0
CENTRAL_DEPLOYMENT=""

while [ $DEPLOYMENT_COUNT -lt $DEPLOYMENT_WAIT ]; do
    CENTRAL_DEPLOYMENT=$(oc get deployment -n "$RHACS_OPERATOR_NAMESPACE" -l app=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$CENTRAL_DEPLOYMENT" ]; then
        log "✓ Central deployment found: $CENTRAL_DEPLOYMENT"
        break
    fi
    sleep 2
    DEPLOYMENT_COUNT=$((DEPLOYMENT_COUNT + 2))
done

if [ -z "$CENTRAL_DEPLOYMENT" ]; then
    warning "Central deployment not found after ${DEPLOYMENT_WAIT} seconds"
    warning "Continuing to wait for Central resource status..."
fi

# Wait for deployment to be ready
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Check deployment readiness
    if [ -n "$CENTRAL_DEPLOYMENT" ]; then
        DEPLOYMENT_READY_REPLICAS=$(oc get deployment "$CENTRAL_DEPLOYMENT" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        DEPLOYMENT_REPLICAS=$(oc get deployment "$CENTRAL_DEPLOYMENT" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        
        if [ "$DEPLOYMENT_READY_REPLICAS" = "$DEPLOYMENT_REPLICAS" ] && [ "$DEPLOYMENT_REPLICAS" != "0" ]; then
            CENTRAL_READY=true
            log "✓ Central deployment is ready ($DEPLOYMENT_READY_REPLICAS/$DEPLOYMENT_REPLICAS replicas)"
            break
        fi
    fi
    
    # Also check Central resource status
    CENTRAL_STATUS=$(oc get central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
    if [ "$CENTRAL_STATUS" = "True" ]; then
        CENTRAL_READY=true
        log "✓ Central is Available"
        break
    fi
    
    # Show progress every 30 seconds
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting... (${WAIT_COUNT}s/${MAX_WAIT}s)"
        
        # Show Central conditions
        CENTRAL_CONDITIONS=$(oc get central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[*].type}:{.status.conditions[*].status}' 2>/dev/null || echo "")
        if [ -n "$CENTRAL_CONDITIONS" ]; then
            log "  Conditions: $CENTRAL_CONDITIONS"
        fi
        
        # Check deployment status
        if [ -n "$CENTRAL_DEPLOYMENT" ]; then
            DEPLOYMENT_READY=$(oc get deployment "$CENTRAL_DEPLOYMENT" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "0/0")
            log "  Deployment: $CENTRAL_DEPLOYMENT ($DEPLOYMENT_READY ready)"
        else
            # Try to find deployment again
            CENTRAL_DEPLOYMENT=$(oc get deployment -n "$RHACS_OPERATOR_NAMESPACE" -l app=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$CENTRAL_DEPLOYMENT" ]; then
                log "  Deployment found: $CENTRAL_DEPLOYMENT"
            fi
        fi
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$CENTRAL_READY" = false ]; then
    warning "Central did not become available within ${MAX_WAIT} seconds"
    log ""
    log "Central deployment details:"
    oc get deployment central -n "$RHACS_OPERATOR_NAMESPACE"
    log ""
    log "Check Central status: oc describe central $CENTRAL_NAME -n $RHACS_OPERATOR_NAMESPACE"
    error "Central is not available. Check the details above and operator logs for more information."
fi

# Verify route type is passthrough
log ""
log "Verifying route configuration..."
CENTRAL_ROUTE=$(oc get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$CENTRAL_ROUTE" ]; then
    ROUTE_TLS_TERMINATION=$(oc get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    if [ "$ROUTE_TLS_TERMINATION" = "passthrough" ]; then
        log "✓ Central route is configured as passthrough: https://$CENTRAL_ROUTE"
    else
        log "Central route: https://$CENTRAL_ROUTE (termination: ${ROUTE_TLS_TERMINATION:-edge})"
        warning "Route termination type is not passthrough. Expected: passthrough, Found: ${ROUTE_TLS_TERMINATION:-edge}"
    fi
else
    warning "Central route not found (may still be creating)"
fi

log ""
log "========================================================="
log "RHACS Central Installation Completed!"
log "========================================================="
log "Namespace: $RHACS_OPERATOR_NAMESPACE"
log "Central Resource: $CENTRAL_NAME"
log "Route Type: Passthrough (TLS terminated at backend)"
if [ -n "$CENTRAL_ROUTE" ]; then
    log "Central URL: https://$CENTRAL_ROUTE"
fi
log "========================================================="
log ""
log "RHACS Central is now deployed with passthrough route."
log ""
