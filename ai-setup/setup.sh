#!/bin/bash

# Master script to install and deploy Red Hat OpenShift AI
# This script orchestrates the installation of OpenShift AI Operator and DataScienceCluster
# Usage: ./setup.sh [--skip-operator] [--skip-cluster]

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
SKIP_OPERATOR=false
SKIP_CLUSTER=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-operator)
            SKIP_OPERATOR=true
            shift
            ;;
        --skip-cluster)
            SKIP_CLUSTER=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-operator    Skip OpenShift AI Operator installation"
            echo "  --skip-cluster    Skip DataScienceCluster deployment"
            echo "  --help, -h         Show this help message"
            echo ""
            echo "This script installs and deploys Red Hat OpenShift AI"
            echo "in the following order:"
            echo "  1. OpenShift AI Operator installation"
            echo "  2. DataScienceCluster deployment"
            exit 0
            ;;
        *)
            error "Unknown option: $1. Use --help for usage information."
            ;;
    esac
done

log "========================================================="
log "Red Hat OpenShift AI Setup"
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
OPERATOR_SCRIPT="${SCRIPT_DIR}/01-operator.sh"
CLUSTER_SCRIPT="${SCRIPT_DIR}/02-cluster.sh"

if [ ! -f "$OPERATOR_SCRIPT" ]; then
    error "Operator script not found: $OPERATOR_SCRIPT"
fi
if [ ! -f "$CLUSTER_SCRIPT" ]; then
    error "Cluster script not found: $CLUSTER_SCRIPT"
fi

log "✓ All required scripts found"
log ""

# Step 1: Install OpenShift AI Operator
if [ "$SKIP_OPERATOR" = false ]; then
    log "========================================================="
    log "Step 1: Installing OpenShift AI Operator"
    log "========================================================="
    log ""
    
    if bash "$OPERATOR_SCRIPT"; then
        log "✓ OpenShift AI Operator installation completed successfully"
    else
        error "OpenShift AI Operator installation failed"
    fi
    log ""
else
    warning "Skipping OpenShift AI Operator installation (--skip-operator)"
    log ""
fi

# Step 2: Deploy DataScienceCluster
if [ "$SKIP_CLUSTER" = false ]; then
    log "========================================================="
    log "Step 2: Deploying DataScienceCluster"
    log "========================================================="
    log ""
    
    if bash "$CLUSTER_SCRIPT"; then
        log "✓ DataScienceCluster deployment completed successfully"
    else
        error "DataScienceCluster deployment failed"
    fi
    log ""
else
    warning "Skipping DataScienceCluster deployment (--skip-cluster)"
    log ""
fi

log "========================================================="
log "OpenShift AI Setup Complete!"
log "========================================================="
log ""
log "All components have been installed and deployed successfully."
log ""
log "To verify the installation:"
log "  oc get pods -n redhat-ods-operator"
log "  oc get datasciencecluster -n redhat-ods-applications"
log "  oc get pods -n redhat-ods-applications"
log ""

# Retrieve OpenShift AI access information
if [ "$SKIP_CLUSTER" = false ]; then
    log "Retrieving OpenShift AI access information..."
    
    DSC_NAMESPACE="redhat-ods-applications"
    DSC_CR_NAME="default-dsc"
    
    # Try to get dashboard route - check for rhods-dashboard first, then fallback to odh-dashboard
    DASHBOARD_ROUTE=$(oc get route rhods-dashboard -n "$DSC_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -z "$DASHBOARD_ROUTE" ]; then
        DASHBOARD_ROUTE=$(oc get route -n "$DSC_NAMESPACE" -l app=odh-dashboard -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
    fi
    
    log ""
    log "========================================================="
    log "OpenShift AI Access Information"
    log "========================================================="
    if [ -n "$DASHBOARD_ROUTE" ]; then
        log "Dashboard URL: https://$DASHBOARD_ROUTE"
    else
        warning "Dashboard URL not yet available. The dashboard route will be created once the DataScienceCluster is fully ready."
        log "  You can check the route status with:"
        log "    oc get route rhods-dashboard -n $DSC_NAMESPACE"
    fi
    log "Username: admin"
    log "Password: OpenShift admin password"
    log "========================================================="
    log ""
fi
