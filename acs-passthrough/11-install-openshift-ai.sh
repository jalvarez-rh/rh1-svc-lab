#!/bin/bash
# OpenShift AI Installation Script
# Installs Red Hat OpenShift AI Operator and creates DataScienceCluster CR
# Note: This script assumes OpenShift AI subscription is already available
# For managed cloud service, subscription must be configured via OpenShift Cluster Manager first

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
    echo -e "${GREEN}[ODH-AI]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[ODH-AI]${NC} $1"
}

error() {
    echo -e "${RED}[ODH-AI] ERROR:${NC} $1" >&2
    echo -e "${RED}[ODH-AI] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Prerequisites validation
log "========================================================="
log "Red Hat OpenShift AI Installation"
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
if ! oc auth can-i create subscriptions --all-namespaces &>/dev/null; then
    error "Cluster admin privileges required to install operators. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log "Prerequisites validated successfully"
log ""

# OpenShift AI operator namespace
OPERATOR_NAMESPACE="redhat-ods-operator"

# Ensure namespace exists
log "Ensuring namespace '$OPERATOR_NAMESPACE' exists..."
if ! oc get namespace "$OPERATOR_NAMESPACE" &>/dev/null; then
    log "Creating namespace '$OPERATOR_NAMESPACE'..."
    oc create namespace "$OPERATOR_NAMESPACE" || error "Failed to create namespace"
fi
log "✓ Namespace '$OPERATOR_NAMESPACE' exists"

# Check if OpenShift AI operator is already installed
log ""
log "Checking Red Hat OpenShift AI operator status"

OPERATOR_PACKAGE="rhods-operator"
EXISTING_SUBSCRIPTION=false

if oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    EXISTING_SUBSCRIPTION=true
    CURRENT_CSV=$(oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    EXISTING_CHANNEL=$(oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
    
    if [ -n "$CURRENT_CSV" ] && [ "$CURRENT_CSV" != "null" ]; then
        if oc get csv "$CURRENT_CSV" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            CSV_PHASE=$(oc get csv "$CURRENT_CSV" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "✓ Red Hat OpenShift AI operator is already installed and running"
                log "  Installed CSV: $CURRENT_CSV"
                log "  Current channel: ${EXISTING_CHANNEL:-unknown}"
                log "  Status: $CSV_PHASE"
            else
                log "Red Hat OpenShift AI operator subscription exists but CSV is in phase: $CSV_PHASE"
            fi
        else
            log "Red Hat OpenShift AI operator subscription exists but CSV not found"
        fi
    else
        log "Red Hat OpenShift AI operator subscription exists but CSV not yet determined"
    fi
else
    log "Red Hat OpenShift AI operator not found, proceeding with installation..."
fi

# Determine preferred channel
log ""
log "Determining available channel for Red Hat OpenShift AI operator..."

CHANNEL=""
if oc get packagemanifest "$OPERATOR_PACKAGE" -n openshift-marketplace >/dev/null 2>&1; then
    AVAILABLE_CHANNELS=$(oc get packagemanifest "$OPERATOR_PACKAGE" -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")
    
    if [ -n "$AVAILABLE_CHANNELS" ]; then
        log "Available channels: $AVAILABLE_CHANNELS"
        
        # Prefer stable channel
        PREFERRED_CHANNELS=("stable" "release-1.0" "beta")
        
        for pref_channel in "${PREFERRED_CHANNELS[@]}"; do
            if echo "$AVAILABLE_CHANNELS" | grep -q "\b$pref_channel\b"; then
                CHANNEL="$pref_channel"
                log "✓ Selected channel: $CHANNEL"
                break
            fi
        done
        
        # If no preferred channel found, use the first available channel
        if [ -z "$CHANNEL" ]; then
            CHANNEL=$(echo "$AVAILABLE_CHANNELS" | awk '{print $1}')
            log "✓ Using first available channel: $CHANNEL"
        fi
    else
        warning "Could not determine available channels from packagemanifest"
    fi
else
    warning "Package manifest not found in catalog (may still be syncing)"
fi

# Fallback to default channel if we couldn't determine it
if [ -z "$CHANNEL" ]; then
    CHANNEL="stable"
    log "Using default channel: $CHANNEL"
fi

# Create or update OperatorGroup
log ""
log "Ensuring OperatorGroup exists with AllNamespaces mode..."

EXISTING_OG=$(oc get operatorgroup -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$EXISTING_OG" ]; then
    # Check if existing OperatorGroup uses AllNamespaces mode
    TARGET_NAMESPACES=$(oc get operatorgroup "$EXISTING_OG" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.targetNamespaces[*]}' 2>/dev/null || echo "")
    
    if [ -n "$TARGET_NAMESPACES" ]; then
        log "Updating OperatorGroup to use AllNamespaces mode..."
        oc patch operatorgroup "$EXISTING_OG" -n "$OPERATOR_NAMESPACE" --type merge -p '{"spec":{"targetNamespaces":[]}}' || warning "Failed to update OperatorGroup"
    else
        log "✓ OperatorGroup already uses AllNamespaces mode"
    fi
else
    log "Creating OperatorGroup with AllNamespaces mode..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: redhat-ods-operatorgroup
  namespace: $OPERATOR_NAMESPACE
spec:
  targetNamespaces: []
EOF
    log "✓ OperatorGroup created"
fi

# Create or update Subscription
log ""
log "Creating/updating Subscription..."
log "  Channel: $CHANNEL"
log "  Source: redhat-operators"
log "  SourceNamespace: openshift-marketplace"

if [ "$EXISTING_SUBSCRIPTION" = true ]; then
    # Update existing subscription if channel changed
    if [ -n "$EXISTING_CHANNEL" ] && [ "$EXISTING_CHANNEL" != "$CHANNEL" ]; then
        log "Updating subscription channel from '$EXISTING_CHANNEL' to '$CHANNEL'..."
        oc patch subscription "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" --type merge -p "{\"spec\":{\"channel\":\"$CHANNEL\"}}" || error "Failed to update subscription channel"
    else
        log "✓ Subscription already exists with channel: $CHANNEL"
    fi
else
    log "Creating Subscription..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $OPERATOR_PACKAGE
  namespace: $OPERATOR_NAMESPACE
spec:
  channel: $CHANNEL
  installPlanApproval: Automatic
  name: $OPERATOR_PACKAGE
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    log "✓ Subscription created"
fi

# Wait for CSV to be created and ready
log ""
log "Waiting for operator CSV to be ready..."
MAX_WAIT=600
WAIT_COUNT=0
CSV_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift AI")].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null | grep rhods | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    fi
    
    if [ -n "$CSV_NAME" ]; then
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            CSV_READY=true
            log "✓ CSV is ready: $CSV_NAME"
            break
        fi
    fi
    
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting... (${WAIT_COUNT}s/${MAX_WAIT}s)"
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$CSV_READY" = false ]; then
    error "CSV did not become ready within ${MAX_WAIT} seconds. Check operator status: oc get csv -n $OPERATOR_NAMESPACE"
fi

# Wait for DataScienceCluster CRD to be available
log ""
log "Waiting for DataScienceCluster CRD to be available..."
MAX_WAIT=120
WAIT_COUNT=0
CRD_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if oc get crd datascienceclusters.datasciencecluster.opendatahub.io 2>/dev/null; then
        CRD_READY=true
        log "✓ DataScienceCluster CRD is available"
        break
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$CRD_READY" = false ]; then
    error "DataScienceCluster CRD not available after ${MAX_WAIT}s"
fi

# Check if DataScienceCluster CR already exists
log ""
log "Checking for existing DataScienceCluster CR..."

DSC_CR_NAME="default-dsc"
DSC_NAMESPACE="redhat-ods-applications"

# Ensure applications namespace exists
if ! oc get namespace "$DSC_NAMESPACE" &>/dev/null; then
    log "Creating namespace '$DSC_NAMESPACE'..."
    oc create namespace "$DSC_NAMESPACE" || error "Failed to create namespace"
fi

if oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" >/dev/null 2>&1; then
    log "✓ DataScienceCluster CR '$DSC_CR_NAME' already exists"
    
    # Check status
    DSC_STATUS=$(oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$DSC_STATUS" = "Ready" ]; then
        log "✓ DataScienceCluster is Ready"
        log ""
        log "========================================================="
        log "Red Hat OpenShift AI Installation Completed!"
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
    
    # Create DataScienceCluster CR with basic components enabled
    # Following the pattern from the documentation, enabling dashboard and workbenches by default
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
        log "  Component status:"
        oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" -o jsonpath='{range .status.installedComponents}{@}{"\n"}{end}' 2>/dev/null || true
    fi
    
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 10))
done

if [ "$DSC_READY" = false ]; then
    warning "DataScienceCluster did not become ready within ${MAX_WAIT} seconds"
    log "Current status:"
    oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" -o yaml
    warning "DataScienceCluster may still be installing. Check operator logs for details."
fi

# Get dashboard route
log ""
log "Retrieving OpenShift AI dashboard route..."

DASHBOARD_ROUTE=$(oc get route -n "$DSC_NAMESPACE" -l app=odh-dashboard -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

log ""
log "========================================================="
log "Red Hat OpenShift AI Installation Completed!"
log "========================================================="
log "Namespace: $DSC_NAMESPACE"
log "DataScienceCluster CR: $DSC_CR_NAME"
log "Status: ${DSC_STATUS:-Installing}"
if [ -n "$DASHBOARD_ROUTE" ]; then
    log "Dashboard URL: https://$DASHBOARD_ROUTE"
fi
log ""
log "Note: To enable additional components, edit the DataScienceCluster CR:"
log "  oc edit datasciencecluster $DSC_CR_NAME -n $DSC_NAMESPACE"
log ""
log "Available components:"
log "  - dashboard (enabled)"
log "  - workbenches (enabled)"
log "  - datasciencepipelines"
log "  - kserve (requires Service Mesh and Serverless)"
log "  - modelmeshserving"
log "  - trainingoperator"
log "  - trustyai"
log "  - codeflare"
log "  - ray"
log "  - kueue"
log "  - llamastackoperator"
log "========================================================="
log ""
