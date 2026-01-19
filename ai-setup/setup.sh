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

# Ensure we're using the local-cluster context
log "Checking OpenShift context..."
CURRENT_CONTEXT=$(oc config current-context 2>/dev/null || echo "")
REQUIRED_CONTEXT="local-cluster"

if [ "$CURRENT_CONTEXT" != "$REQUIRED_CONTEXT" ]; then
    log "Current context is '$CURRENT_CONTEXT', switching to '$REQUIRED_CONTEXT'..."
    
    # Check if local-cluster context exists
    if ! oc config get-contexts "$REQUIRED_CONTEXT" >/dev/null 2>&1; then
        error "Context '$REQUIRED_CONTEXT' not found. Please ensure the context is configured: oc config get-contexts"
    fi
    
    # Switch to local-cluster context
    if oc config use-context "$REQUIRED_CONTEXT" >/dev/null 2>&1; then
        log "✓ Switched to '$REQUIRED_CONTEXT' context"
    else
        error "Failed to switch to '$REQUIRED_CONTEXT' context"
    fi
else
    log "✓ Already using '$REQUIRED_CONTEXT' context"
fi

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
# This script (01-operator.sh) installs:
# - Namespace: redhat-ods-operator
# - OperatorGroup: redhat-ods-operatorgroup (AllNamespaces mode)
# - Subscription: rhods-operator (from redhat-operators)
# - Waits for CSV to be ready
# - Waits for DataScienceCluster CRD to be available
# - Namespace: redhat-ods-applications
# - DataScienceCluster CR: default-dsc (with dashboard and workbenches enabled)
# - Waits for DataScienceCluster to be Ready
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
# This script (02-cluster.sh) ensures:
# - DataScienceCluster CRD exists (validates operator is installed)
# - Namespace: redhat-ods-applications exists
# - DataScienceCluster CR: default-dsc exists (creates if needed)
# - Waits for DataScienceCluster to be Ready
# Note: If 01-operator.sh already created the DataScienceCluster CR, this script
#       will detect it exists and wait for it to be ready (idempotent operation)
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
    
    # Try to retrieve OpenShift admin password
    log "Retrieving OpenShift admin password..."
    ADMIN_PASSWORD=""
    
    # First, check for ACS_PORTAL_PASSWORD from environment (set in ~/.bashrc)
    if [ -n "${ACS_PORTAL_PASSWORD:-}" ]; then
        ADMIN_PASSWORD="$ACS_PORTAL_PASSWORD"
        log "✓ Using password from ACS_PORTAL_PASSWORD environment variable"
    else
        # Try to source it from ~/.bashrc if not in current environment
        if [ -f ~/.bashrc ]; then
            # Extract ACS_PORTAL_PASSWORD from ~/.bashrc
            EXTRACTED_PASSWORD=$(grep -E "^export ACS_PORTAL_PASSWORD=" ~/.bashrc | sed 's/^export ACS_PORTAL_PASSWORD="\(.*\)"/\1/' | sed "s/^export ACS_PORTAL_PASSWORD='\(.*\)'/\1/" | sed 's/^export ACS_PORTAL_PASSWORD=\(.*\)/\1/' | head -1)
            if [ -n "$EXTRACTED_PASSWORD" ]; then
                ADMIN_PASSWORD="$EXTRACTED_PASSWORD"
                log "✓ Retrieved password from ACS_PORTAL_PASSWORD in ~/.bashrc"
            fi
        fi
    fi
    
    # If still not found, try to get kubeadmin password from kube-system namespace
    if [ -z "$ADMIN_PASSWORD" ]; then
        KUBEADMIN_PASSWORD_B64=$(oc get secret kubeadmin -n kube-system -o jsonpath='{.data.password}' 2>/dev/null || echo "")
        if [ -n "$KUBEADMIN_PASSWORD_B64" ]; then
            ADMIN_PASSWORD=$(echo "$KUBEADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || echo "")
            if [ -n "$ADMIN_PASSWORD" ]; then
                log "✓ Retrieved kubeadmin password from secret"
            fi
        fi
    fi
    
    # If still not found, check for other environment variables
    if [ -z "$ADMIN_PASSWORD" ] && [ -n "${OPENSHIFT_ADMIN_PASSWORD:-}" ]; then
        ADMIN_PASSWORD="$OPENSHIFT_ADMIN_PASSWORD"
        log "✓ Using password from OPENSHIFT_ADMIN_PASSWORD environment variable"
    fi
    
    if [ -z "$ADMIN_PASSWORD" ] && [ -n "${AWS_OPENSHIFT_KUBEADMIN_PASSWORD:-}" ]; then
        ADMIN_PASSWORD="$AWS_OPENSHIFT_KUBEADMIN_PASSWORD"
        log "✓ Using password from AWS_OPENSHIFT_KUBEADMIN_PASSWORD environment variable"
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
    if [ -n "$ADMIN_PASSWORD" ]; then
        log "Password: $ADMIN_PASSWORD"
    else
        log "Password: OpenShift admin password"
    fi
    log "========================================================="
    log ""
fi
