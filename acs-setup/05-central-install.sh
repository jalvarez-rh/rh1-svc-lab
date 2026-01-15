#!/bin/bash
# RHACS Central Installation Script
# Creates Central custom resource to deploy RHACS Central

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

# Verify TLS certificate secret exists
CENTRAL_TLS_SECRET_NAME="central-default-tls-cert"
log ""
log "Verifying TLS certificate secret exists..."
if ! oc get secret "$CENTRAL_TLS_SECRET_NAME" -n "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    error "Secret '$CENTRAL_TLS_SECRET_NAME' not found in namespace '$RHACS_OPERATOR_NAMESPACE'. Please run the TLS certificate setup script first."
fi
log "✓ TLS certificate secret '$CENTRAL_TLS_SECRET_NAME' found"

# Get Central DNS name from the certificate (if available)
CENTRAL_DNS_NAME=""
CERT_NAME="rhacs-central-tls-cert"
if oc get certificate "$CERT_NAME" -n "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    CENTRAL_DNS_NAME=$(oc get certificate "$CERT_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.dnsNames[0]}' 2>/dev/null || echo "")
fi

# Central resource name
CENTRAL_NAME="rhacs-central-services"

# Check if Central already exists
log ""
log "Checking if Central resource already exists..."
if oc get central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    log "Central resource '$CENTRAL_NAME' already exists"
    
    # Check if it's using the correct TLS secret
    EXISTING_TLS_SECRET=$(oc get central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.central.defaultTLSSecret.name}' 2>/dev/null || echo "")
    if [ "$EXISTING_TLS_SECRET" != "$CENTRAL_TLS_SECRET_NAME" ]; then
        warning "Central exists but is not using the expected TLS secret"
        warning "Expected: $CENTRAL_TLS_SECRET_NAME, Found: ${EXISTING_TLS_SECRET:-none}"
        log "Updating Central to use the correct TLS secret..."
        
        oc patch central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" --type merge -p "{\"spec\":{\"central\":{\"defaultTLSSecret\":{\"name\":\"$CENTRAL_TLS_SECRET_NAME\"}}}}" || error "Failed to update Central TLS secret"
        log "✓ Central updated to use TLS secret: $CENTRAL_TLS_SECRET_NAME"
    else
        log "✓ Central is already configured with the correct TLS secret"
    fi
    
    # Check Central status
    CENTRAL_STATUS=$(oc get central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
    if [ "$CENTRAL_STATUS" = "True" ]; then
        log "✓ Central is Available"
    else
        log "Central status: $CENTRAL_STATUS (may still be deploying)"
    fi
else
    log "Creating Central resource..."
    
    # Build Central CR YAML
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
    
    # Add TLS secret reference
    CENTRAL_YAML="${CENTRAL_YAML}
    defaultTLSSecret:
      name: $CENTRAL_TLS_SECRET_NAME"
    
    # Apply the Central resource
    echo "$CENTRAL_YAML" | oc apply -f - || error "Failed to create Central resource"
    log "✓ Central resource created"
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

# Get Central route information
log ""
log "Retrieving Central route information..."
CENTRAL_ROUTE=$(oc get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$CENTRAL_ROUTE" ]; then
    log "✓ Central route: https://$CENTRAL_ROUTE"
else
    warning "Central route not found (may still be creating)"
fi

log ""
log "========================================================="
log "RHACS Central Installation Completed!"
log "========================================================="
log "Namespace: $RHACS_OPERATOR_NAMESPACE"
log "Central Resource: $CENTRAL_NAME"
if [ -n "$CENTRAL_ROUTE" ]; then
    log "Central URL: https://$CENTRAL_ROUTE"
fi
log "========================================================="
log ""
log "RHACS Central is now deployed and ready."
log ""

