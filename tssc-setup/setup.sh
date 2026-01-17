#!/bin/bash

# Master script to install and deploy Red Hat Trusted Artifact Signer (RHTAS)
# This script orchestrates the installation of Keycloak, RHTAS Operator, and RHTAS components
# Usage: ./setup.sh [--skip-keycloak] [--skip-operator] [--skip-deploy]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[SETUP] ERROR:${NC} $1" >&2
    exit 1
}

info() {
    echo -e "${BLUE}[SETUP]${NC} $1"
}

# Parse command line arguments
SKIP_KEYCLOAK=false
SKIP_OPERATOR=false
SKIP_DEPLOY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-keycloak)
            SKIP_KEYCLOAK=true
            shift
            ;;
        --skip-operator)
            SKIP_OPERATOR=true
            shift
            ;;
        --skip-deploy)
            SKIP_DEPLOY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-keycloak    Skip Keycloak installation"
            echo "  --skip-operator    Skip RHTAS Operator installation"
            echo "  --skip-deploy      Skip RHTAS component deployment"
            echo "  --help, -h         Show this help message"
            echo ""
            echo "This script installs and deploys Red Hat Trusted Artifact Signer (RHTAS)"
            echo "in the following order:"
            echo "  1. Keycloak (RHSSO) installation"
            echo "  2. RHTAS Operator installation"
            echo "  3. RHTAS component deployment"
            exit 0
            ;;
        *)
            error "Unknown option: $1. Use --help for usage information."
            ;;
    esac
done

log "========================================================="
log "Red Hat Trusted Artifact Signer (RHTAS) Setup"
log "========================================================="
log ""

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami >/dev/null 2>&1; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Check if scripts exist
KEYCLOAK_SCRIPT="${SCRIPT_DIR}/01-keycloak.sh"
OPERATOR_SCRIPT="${SCRIPT_DIR}/02-operator.sh"
DEPLOY_SCRIPT="${SCRIPT_DIR}/03-deploy.sh"

if [ ! -f "$KEYCLOAK_SCRIPT" ]; then
    error "Keycloak script not found: $KEYCLOAK_SCRIPT"
fi
if [ ! -f "$OPERATOR_SCRIPT" ]; then
    error "Operator script not found: $OPERATOR_SCRIPT"
fi
if [ ! -f "$DEPLOY_SCRIPT" ]; then
    error "Deploy script not found: $DEPLOY_SCRIPT"
fi

log "✓ All required scripts found"
log ""

# Step 1: Install Keycloak
if [ "$SKIP_KEYCLOAK" = false ]; then
    log "========================================================="
    log "Step 1: Installing Keycloak (RHSSO)"
    log "========================================================="
    log ""
    
    if bash "$KEYCLOAK_SCRIPT"; then
        log "✓ Keycloak installation completed successfully"
    else
        error "Keycloak installation failed"
    fi
    log ""
else
    warning "Skipping Keycloak installation (--skip-keycloak)"
    log ""
fi

# Step 2: Install RHTAS Operator
if [ "$SKIP_OPERATOR" = false ]; then
    log "========================================================="
    log "Step 2: Installing RHTAS Operator"
    log "========================================================="
    log ""
    
    if bash "$OPERATOR_SCRIPT"; then
        log "✓ RHTAS Operator installation completed successfully"
    else
        error "RHTAS Operator installation failed"
    fi
    log ""
else
    warning "Skipping RHTAS Operator installation (--skip-operator)"
    log ""
fi

# Step 3: Deploy RHTAS Components
if [ "$SKIP_DEPLOY" = false ]; then
    log "========================================================="
    log "Step 3: Deploying RHTAS Components"
    log "========================================================="
    log ""
    
    if bash "$DEPLOY_SCRIPT"; then
        log "✓ RHTAS component deployment completed successfully"
    else
        error "RHTAS component deployment failed"
    fi
    log ""
else
    warning "Skipping RHTAS component deployment (--skip-deploy)"
    log ""
fi

log "========================================================="
log "RHTAS Setup Complete!"
log "========================================================="
log ""
log "All components have been installed and deployed successfully."
log ""
log "To verify the installation:"
log "  oc get pods -n rhsso"
log "  oc get pods -n trusted-artifact-signer"
log "  oc get securesigns -n trusted-artifact-signer"
log ""
log "To get cosign configuration URLs, run:"
log "  bash ${DEPLOY_SCRIPT}"
log ""
