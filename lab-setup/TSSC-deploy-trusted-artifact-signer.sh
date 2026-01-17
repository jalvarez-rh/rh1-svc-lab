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

# API version is confirmed from CRDs
RHTAS_API_VERSION="rhtas.redhat.com/v1alpha1"
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

# Step 2: Deploy Securesign CR (manages TUF, Fulcio, and Rekor)
log ""
log "Step 2: Deploying RHTAS components..."

# Check if Securesign CRD exists
SECURESIGN_CRD_EXISTS=false
if oc get crd securesigns.rhtas.redhat.com >/dev/null 2>&1; then
    SECURESIGN_CRD_EXISTS=true
    log "Securesign CRD found - using Securesign CR to manage components"
    
    SECURESIGN_NAME="securesign"
    if oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
        log "✓ Securesign CR '${SECURESIGN_NAME}' already exists"
    else
        log "Creating Securesign CR..."
        if ! cat <<EOF | oc apply -f -
apiVersion: ${RHTAS_API_VERSION}
kind: Securesign
metadata:
  name: ${SECURESIGN_NAME}
  namespace: ${RHTAS_NAMESPACE}
spec:
  fulcio:
    externalAccess:
      enabled: true
    oidc:
      issuer: ${OIDC_ISSUER_URL}
      clientID: ${OIDC_CLIENT_ID}
  rekor:
    externalAccess:
      enabled: true
  tuf:
    externalAccess:
      enabled: true
    keys:
      - name: rekor.pub
      - name: ctfe.pub
      - name: fulcio_v1.crt.pem
    pvc:
      accessModes:
        - ReadWriteOnce
      retain: true
      size: 100Mi
EOF
        then
            error "Failed to create Securesign CR. Check if the API version is correct: ${RHTAS_API_VERSION}"
        fi
        log "✓ Securesign CR created successfully"
    fi
else
    log "Securesign CRD not found - creating individual component CRs"
    SECURESIGN_NAME=""
    
    # Create TUF CR
    log "Creating TUF CR..."
    TUF_NAME="tuf"
    if oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
        log "✓ TUF CR '${TUF_NAME}' already exists"
    else
        if ! cat <<EOF | oc apply -f -
apiVersion: ${RHTAS_API_VERSION}
kind: Tuf
metadata:
  name: ${TUF_NAME}
  namespace: ${RHTAS_NAMESPACE}
spec:
  externalAccess:
    enabled: true
  keys:
    - name: rekor.pub
    - name: ctfe.pub
    - name: fulcio_v1.crt.pem
  pvc:
    accessModes:
      - ReadWriteOnce
    retain: true
    size: 100Mi
EOF
        then
            error "Failed to create TUF CR"
        fi
        log "✓ TUF CR created successfully"
    fi
    
    # Create Fulcio CR
    log "Creating Fulcio CR with Keycloak OIDC..."
    FULCIO_NAME="fulcio-server"
    if oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
        log "✓ Fulcio CR '${FULCIO_NAME}' already exists"
    else
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
    
    # Create Rekor CR
    log "Creating Rekor CR..."
    REKOR_NAME="rekor-server"
    if oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
        log "✓ Rekor CR '${REKOR_NAME}' already exists"
    else
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
fi

# Wait for components to be ready
log ""
log "Waiting for RHTAS components to be ready..."

MAX_WAIT=600
WAIT_COUNT=0
TUF_READY=false
FULCIO_READY=false
REKOR_READY=false

# Initialize component names if not set (for individual CR creation path)
if [ -z "${TUF_NAME:-}" ]; then
    TUF_NAME=""
fi
if [ -z "${FULCIO_NAME:-}" ]; then
    FULCIO_NAME=""
fi
if [ -z "${REKOR_NAME:-}" ]; then
    REKOR_NAME=""
fi

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Check TUF status
    if [ -z "$TUF_NAME" ]; then
        if [ -n "$SECURESIGN_NAME" ]; then
            # Created as child of Securesign
            TUF_NAME=$(oc get tufs -n $RHTAS_NAMESPACE -l app.kubernetes.io/instance=${SECURESIGN_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        fi
        if [ -z "$TUF_NAME" ]; then
            # Try without label selector or use default name
            TUF_NAME=$(oc get tufs -n $RHTAS_NAMESPACE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "tuf")
        fi
    fi
    
    if [ -n "$TUF_NAME" ] && oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
        TUF_CONDITION=$(oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$TUF_CONDITION" = "True" ]; then
            if [ "$TUF_READY" = false ]; then
                TUF_URL=$(oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
                log "✓ TUF is ready at: ${TUF_URL}"
                TUF_READY=true
            fi
        fi
    fi
    
    # Check Fulcio status
    if [ -z "$FULCIO_NAME" ]; then
        if [ -n "$SECURESIGN_NAME" ]; then
            FULCIO_NAME=$(oc get fulcios -n $RHTAS_NAMESPACE -l app.kubernetes.io/instance=${SECURESIGN_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        fi
        if [ -z "$FULCIO_NAME" ]; then
            FULCIO_NAME=$(oc get fulcios -n $RHTAS_NAMESPACE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "fulcio-server")
        fi
    fi
    
    if [ -n "$FULCIO_NAME" ] && oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
        FULCIO_STATUS=$(oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        FULCIO_URL=$(oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
        if [ "$FULCIO_STATUS" = "PhaseReady" ] && [ -n "$FULCIO_URL" ]; then
            if [ "$FULCIO_READY" = false ]; then
                log "✓ Fulcio is ready at: ${FULCIO_URL}"
                FULCIO_READY=true
            fi
        fi
    fi
    
    # Check Rekor status
    if [ -z "$REKOR_NAME" ]; then
        if [ -n "$SECURESIGN_NAME" ]; then
            REKOR_NAME=$(oc get rekors -n $RHTAS_NAMESPACE -l app.kubernetes.io/instance=${SECURESIGN_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        fi
        if [ -z "$REKOR_NAME" ]; then
            REKOR_NAME=$(oc get rekors -n $RHTAS_NAMESPACE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "rekor-server")
        fi
    fi
    
    if [ -n "$REKOR_NAME" ] && oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
        REKOR_STATUS=$(oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        REKOR_URL=$(oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
        if [ "$REKOR_STATUS" = "PhaseReady" ] && [ -n "$REKOR_URL" ]; then
            if [ "$REKOR_READY" = false ]; then
                log "✓ Rekor is ready at: ${REKOR_URL}"
                REKOR_READY=true
            fi
        fi
    fi
    
    # If all are ready, break
    if [ "$TUF_READY" = true ] && [ "$FULCIO_READY" = true ] && [ "$REKOR_READY" = true ]; then
        break
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Progress (${WAIT_COUNT}s/${MAX_WAIT}s):"
        log "    TUF: ${TUF_READY:-false}"
        log "    Fulcio: ${FULCIO_READY:-false}"
        log "    Rekor: ${REKOR_READY:-false}"
    fi
done

# Get final URLs
if [ "$TUF_READY" = false ] && [ -n "$TUF_NAME" ]; then
    TUF_URL=$(oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
fi
if [ "$FULCIO_READY" = false ] && [ -n "$FULCIO_NAME" ]; then
    FULCIO_URL=$(oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
fi
if [ "$REKOR_READY" = false ] && [ -n "$REKOR_NAME" ]; then
    REKOR_URL=$(oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
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
log "  oc get tufs,fulcios,rekors -n ${RHTAS_NAMESPACE}"
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
