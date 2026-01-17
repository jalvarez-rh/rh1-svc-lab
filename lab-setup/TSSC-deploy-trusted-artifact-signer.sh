#!/bin/bash

# Script to deploy Red Hat Trusted Artifact Signer (RHTAS) components
# Assumes oc is installed and user is logged in as cluster-admin
# Assumes RHTAS Operator is installed and Keycloak is configured
# Usage: ./TSSC-deploy-trusted-artifact-signer.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RHTAS-DEPLOY]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHTAS-DEPLOY]${NC} $1"
}

error() {
    echo -e "${RED}[RHTAS-DEPLOY] ERROR:${NC} $1" >&2
    exit 1
}

log "========================================================="
log "Red Hat Trusted Artifact Signer Component Deployment"
log "========================================================="
log ""

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami >/dev/null 2>&1; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Check if RHTAS Operator is installed
log "Checking if RHTAS Operator is installed..."
if ! oc get csv -n openshift-operators | grep -qi "trusted-artifact-signer\|rhtas"; then
    error "RHTAS Operator not found. Please install it first by running: ./TSSC-install-trusted-artifact-signer.sh"
fi
log "✓ RHTAS Operator found"

# Check if Keycloak is available
log "Checking if Keycloak is available..."
KEYCLOAK_NAMESPACE="rhsso"
if ! oc get namespace $KEYCLOAK_NAMESPACE >/dev/null 2>&1; then
    error "Keycloak namespace '$KEYCLOAK_NAMESPACE' not found. Please install Keycloak first."
fi

KEYCLOAK_ROUTE=$(oc get route keycloak -n $KEYCLOAK_NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$KEYCLOAK_ROUTE" ]; then
    error "Keycloak route not found. Please ensure Keycloak is installed and running."
fi
log "✓ Keycloak is available at: https://${KEYCLOAK_ROUTE}"

# Get OIDC configuration
OIDC_ISSUER_URL="https://${KEYCLOAK_ROUTE}/auth/realms/openshift"
OIDC_CLIENT_ID="trusted-artifact-signer"
log "✓ OIDC Issuer URL: ${OIDC_ISSUER_URL}"
log "✓ OIDC Client ID: ${OIDC_CLIENT_ID}"

log "Prerequisites validated successfully"
log ""

# Detect API version
log "Detecting RHTAS API version..."
RHTAS_API_VERSION="rhtas.redhat.com/v1alpha1"
if ! oc api-resources | grep -q "rhtas.redhat.com"; then
    # Try alternative API group
    if oc api-resources | grep -q "trustedartifactsigner"; then
        RHTAS_API_VERSION="trustedartifactsigner.redhat.com/v1alpha1"
    else
        warning "Could not detect RHTAS API version, using default: ${RHTAS_API_VERSION}"
    fi
fi
log "Using API version: ${RHTAS_API_VERSION}"
log ""

# Step 1: Create namespace
RHTAS_NAMESPACE="trusted-artifact-signer"
log "Step 1: Creating namespace '${RHTAS_NAMESPACE}'..."

if oc get namespace $RHTAS_NAMESPACE >/dev/null 2>&1; then
    log "✓ Namespace '${RHTAS_NAMESPACE}' already exists"
else
    if ! oc create namespace $RHTAS_NAMESPACE; then
        error "Failed to create namespace '${RHTAS_NAMESPACE}'"
    fi
    log "✓ Namespace created successfully"
fi

# Step 2: Deploy TUF (The Update Framework)
log ""
log "Step 2: Deploying TUF (The Update Framework)..."

TUF_NAME="tuf"
if oc get tuf $TUF_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
    log "✓ TUF CR '${TUF_NAME}' already exists"
else
    log "Creating TUF CR..."
    if ! cat <<EOF | oc apply -f -
apiVersion: ${RHTAS_API_VERSION}
kind: TUF
metadata:
  name: ${TUF_NAME}
  namespace: ${RHTAS_NAMESPACE}
spec:
  externalAccess:
    enabled: true
EOF
    then
        error "Failed to create TUF CR. Check if the API version is correct: ${RHTAS_API_VERSION}"
    fi
    log "✓ TUF CR created successfully"
fi

# Wait for TUF to be ready
log "Waiting for TUF to be ready..."
MAX_WAIT_TUF=300
WAIT_COUNT=0
TUF_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT_TUF ]; do
    TUF_STATUS=$(oc get tuf $TUF_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    TUF_URL=$(oc get tuf $TUF_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
    
    if [ "$TUF_STATUS" = "PhaseReady" ] && [ -n "$TUF_URL" ]; then
        TUF_READY=true
        log "✓ TUF is ready at: ${TUF_URL}"
        break
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting for TUF... (${WAIT_COUNT}s/${MAX_WAIT_TUF}s) - Phase: ${TUF_STATUS:-unknown}"
    fi
done

if [ "$TUF_READY" = false ]; then
    warning "TUF did not become ready within ${MAX_WAIT_TUF} seconds"
    TUF_URL=$(oc get tuf $TUF_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
    if [ -z "$TUF_URL" ]; then
        warning "TUF URL not yet available"
    fi
fi

# Step 3: Deploy Fulcio with Keycloak OIDC
log ""
log "Step 3: Deploying Fulcio with Keycloak OIDC integration..."

FULCIO_NAME="fulcio-server"
if oc get fulcio $FULCIO_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
    log "✓ Fulcio CR '${FULCIO_NAME}' already exists"
else
    log "Creating Fulcio CR with Keycloak OIDC..."
    if ! cat <<EOF | oc apply -f -
apiVersion: ${RHTAS_API_VERSION}
kind: Fulcio
metadata:
  name: ${FULCIO_NAME}
  namespace: ${RHTAS_NAMESPACE}
spec:
  externalAccess:
    enabled: true
  oidc:
    issuer: ${OIDC_ISSUER_URL}
    clientID: ${OIDC_CLIENT_ID}
EOF
    then
        error "Failed to create Fulcio CR"
    fi
    log "✓ Fulcio CR created successfully"
fi

# Wait for Fulcio to be ready
log "Waiting for Fulcio to be ready..."
MAX_WAIT_FULCIO=300
WAIT_COUNT=0
FULCIO_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT_FULCIO ]; do
    FULCIO_STATUS=$(oc get fulcio $FULCIO_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    FULCIO_URL=$(oc get fulcio $FULCIO_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
    
    if [ "$FULCIO_STATUS" = "PhaseReady" ] && [ -n "$FULCIO_URL" ]; then
        FULCIO_READY=true
        log "✓ Fulcio is ready at: ${FULCIO_URL}"
        break
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting for Fulcio... (${WAIT_COUNT}s/${MAX_WAIT_FULCIO}s) - Phase: ${FULCIO_STATUS:-unknown}"
    fi
done

if [ "$FULCIO_READY" = false ]; then
    warning "Fulcio did not become ready within ${MAX_WAIT_FULCIO} seconds"
    FULCIO_URL=$(oc get fulcio $FULCIO_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
    if [ -z "$FULCIO_URL" ]; then
        warning "Fulcio URL not yet available"
    fi
fi

# Step 4: Deploy Rekor
log ""
log "Step 4: Deploying Rekor (Transparency Log)..."

REKOR_NAME="rekor-server"
if oc get rekor $REKOR_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
    log "✓ Rekor CR '${REKOR_NAME}' already exists"
else
    log "Creating Rekor CR..."
    if ! cat <<EOF | oc apply -f -
apiVersion: ${RHTAS_API_VERSION}
kind: Rekor
metadata:
  name: ${REKOR_NAME}
  namespace: ${RHTAS_NAMESPACE}
spec:
  externalAccess:
    enabled: true
EOF
    then
        error "Failed to create Rekor CR"
    fi
    log "✓ Rekor CR created successfully"
fi

# Wait for Rekor to be ready
log "Waiting for Rekor to be ready..."
MAX_WAIT_REKOR=300
WAIT_COUNT=0
REKOR_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT_REKOR ]; do
    REKOR_STATUS=$(oc get rekor $REKOR_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    REKOR_URL=$(oc get rekor $REKOR_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
    
    if [ "$REKOR_STATUS" = "PhaseReady" ] && [ -n "$REKOR_URL" ]; then
        REKOR_READY=true
        log "✓ Rekor is ready at: ${REKOR_URL}"
        break
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting for Rekor... (${WAIT_COUNT}s/${MAX_WAIT_REKOR}s) - Phase: ${REKOR_STATUS:-unknown}"
    fi
done

if [ "$REKOR_READY" = false ]; then
    warning "Rekor did not become ready within ${MAX_WAIT_REKOR} seconds"
    REKOR_URL=$(oc get rekor $REKOR_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
    if [ -z "$REKOR_URL" ]; then
        warning "Rekor URL not yet available"
    fi
fi

# Step 5: Summary
log ""
log "========================================================="
log "RHTAS Deployment Summary"
log "========================================================="
log "Namespace: ${RHTAS_NAMESPACE}"
log ""

if [ "$TUF_READY" = true ]; then
    log "✓ TUF: Ready"
    log "  URL: ${TUF_URL}"
else
    warning "TUF: Not ready"
fi

if [ "$FULCIO_READY" = true ]; then
    log "✓ Fulcio: Ready"
    log "  URL: ${FULCIO_URL}"
    log "  OIDC Issuer: ${OIDC_ISSUER_URL}"
    log "  OIDC Client ID: ${OIDC_CLIENT_ID}"
else
    warning "Fulcio: Not ready"
fi

if [ "$REKOR_READY" = true ]; then
    log "✓ Rekor: Ready"
    log "  URL: ${REKOR_URL}"
else
    warning "Rekor: Not ready"
fi

log ""
log "To check status:"
log "  oc get tuf,fulcio,rekor -n ${RHTAS_NAMESPACE}"
log "  oc get pods -n ${RHTAS_NAMESPACE}"
log ""
log "To get URLs for cosign configuration:"
if [ -n "$TUF_URL" ]; then
    log "  export TUF_URL=${TUF_URL}"
fi
if [ -n "$FULCIO_URL" ]; then
    log "  export COSIGN_FULCIO_URL=${FULCIO_URL}"
fi
if [ -n "$REKOR_URL" ]; then
    log "  export COSIGN_REKOR_URL=${REKOR_URL}"
fi
log "  export OIDC_ISSUER_URL=${OIDC_ISSUER_URL}"
log "  export COSIGN_OIDC_CLIENT_ID=${OIDC_CLIENT_ID}"
log "========================================================="
log ""
