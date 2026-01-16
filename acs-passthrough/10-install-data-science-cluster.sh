#!/bin/bash
# DataScienceCluster Installation Script
# Creates or updates DataScienceCluster CR to install OpenShift AI components
# Assumes OpenShift AI Operator is already installed

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
    echo -e "${GREEN}[DSC-INSTALL]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[DSC-INSTALL]${NC} $1"
}

error() {
    echo -e "${RED}[DSC-INSTALL] ERROR:${NC} $1" >&2
    echo -e "${RED}[DSC-INSTALL] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Prerequisites validation
log "========================================================="
log "DataScienceCluster Installation"
log "========================================================="
log ""

log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Check if we have cluster admin privileges
log "Checking cluster admin privileges..."
if ! oc auth can-i create datascienceclusters --all-namespaces &>/dev/null; then
    warning "May not have permissions to create DataScienceCluster CR"
fi

# Check if DataScienceCluster CRD exists
log "Checking for DataScienceCluster CRD..."
if ! oc get crd datascienceclusters.datasciencecluster.opendatahub.io &>/dev/null; then
    error "DataScienceCluster CRD not found. Please install OpenShift AI Operator first."
fi
log "✓ DataScienceCluster CRD is available"

log "Prerequisites validated successfully"
log ""

# DataScienceCluster configuration
DSC_CR_NAME="default-dsc"
DSC_NAMESPACE="redhat-ods-applications"

# Ensure applications namespace exists
log "Ensuring namespace '$DSC_NAMESPACE' exists..."
if ! oc get namespace "$DSC_NAMESPACE" &>/dev/null; then
    log "Creating namespace '$DSC_NAMESPACE'..."
    oc create namespace "$DSC_NAMESPACE" || error "Failed to create namespace"
fi
log "✓ Namespace '$DSC_NAMESPACE' exists"

# Check if DataScienceCluster CR already exists
log ""
log "Checking for existing DataScienceCluster CR..."

if oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" >/dev/null 2>&1; then
    log "✓ DataScienceCluster CR '$DSC_CR_NAME' already exists"
    
    # Check status
    DSC_STATUS=$(oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$DSC_STATUS" = "Ready" ]; then
        log "✓ DataScienceCluster is Ready"
        log ""
        log "========================================================="
        log "DataScienceCluster Installation Completed!"
        log "========================================================="
        log "Namespace: $DSC_NAMESPACE"
        log "DataScienceCluster CR: $DSC_CR_NAME"
        log "Status: Ready"
        log "========================================================="
        exit 0
    else
        log "DataScienceCluster exists but status is: ${DSC_STATUS:-Unknown}"
        log "Waiting for it to become ready..."
    fi
else
    log "Creating DataScienceCluster CR..."
    
    # Create DataScienceCluster CR with components enabled
    # Dashboard and workbenches are enabled by default
    cat <<EOF | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: $DSC_CR_NAME
  namespace: $DSC_NAMESPACE
spec:
  components:
    codeflare:
      managementState: Removed
    dashboard:
      managementState: Managed
    datasciencepipelines:
      managementState: Removed
    feastoperator:
      managementState: Removed
    kserve:
      managementState: Removed
    kueue:
      managementState: Removed
    llamastackoperator:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
    modelregistry:
      managementState: Removed
    ray:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      managementState: Removed
    workbenches:
      managementState: Managed
      workbenchNamespace: rhods-notebooks
EOF
    log "✓ DataScienceCluster CR created"
fi

# Wait for DataScienceCluster to be ready
log ""
log "Waiting for DataScienceCluster to become ready..."
MAX_WAIT=900
WAIT_COUNT=0
DSC_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    DSC_STATUS=$(oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    
    if [ "$DSC_STATUS" = "Ready" ]; then
        DSC_READY=true
        log "✓ DataScienceCluster is Ready"
        break
    fi
    
    if [ $((WAIT_COUNT % 60)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting... (${WAIT_COUNT}s/${MAX_WAIT}s)"
        log "  Current status: ${DSC_STATUS:-Unknown}"
        
        # Show component status
        INSTALLED_COMPONENTS=$(oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" -o jsonpath='{range .status.installedComponents}{@}{"\n"}{end}' 2>/dev/null || echo "")
        if [ -n "$INSTALLED_COMPONENTS" ]; then
            log "  Installed components:"
            echo "$INSTALLED_COMPONENTS" | while read -r component; do
                log "    - $component"
            done
        fi
    fi
    
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 10))
done

if [ "$DSC_READY" = false ]; then
    warning "DataScienceCluster did not become ready within ${MAX_WAIT} seconds"
    log "Current status:"
    oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" -o yaml | head -50
    warning "DataScienceCluster may still be installing. Check operator logs for details."
fi

# Get component status
log ""
log "Retrieving component status..."

DASHBOARD_ROUTE=$(oc get route -n "$DSC_NAMESPACE" -l app=odh-dashboard -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

# Get installed components
INSTALLED_COMPONENTS=$(oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" -o jsonpath='{.status.installedComponents}' 2>/dev/null || echo "{}")

log ""
log "========================================================="
log "DataScienceCluster Installation Completed!"
log "========================================================="
log "Namespace: $DSC_NAMESPACE"
log "DataScienceCluster CR: $DSC_CR_NAME"
log "Status: ${DSC_STATUS:-Installing}"
log ""
log "Installed Components:"
log "  - dashboard: Managed"
log "  - workbenches: Managed"
log ""
if [ -n "$DASHBOARD_ROUTE" ]; then
    log "Dashboard URL: https://$DASHBOARD_ROUTE"
fi
log ""
log "Note: To enable additional components, edit the DataScienceCluster CR:"
log "  oc edit datasciencecluster $DSC_CR_NAME -n $DSC_NAMESPACE"
log ""

# Get OpenShift console URL and credentials
log "Retrieving access information..."

OPENSHIFT_CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "")
CURRENT_USER=$(oc whoami 2>/dev/null || echo "")

log ""
log "========================================================="
log "OpenShift AI Access Information"
log "========================================================="
if [ -n "$DASHBOARD_ROUTE" ]; then
    log "Dashboard URL: https://$DASHBOARD_ROUTE"
fi
if [ -n "$OPENSHIFT_CONSOLE_URL" ]; then
    log "OpenShift Console: $OPENSHIFT_CONSOLE_URL"
fi
if [ -n "$CURRENT_USER" ]; then
    log "Username: $CURRENT_USER"
fi
log "Password: Use your OpenShift cluster credentials"
log "========================================================="
log ""
