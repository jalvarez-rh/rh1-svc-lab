#!/bin/bash
# RHACS Operator Cleanup Script
# Deletes all RHACS-related operators from the OpenShift cluster
# This script is idempotent and safe to run multiple times

# Exit immediately on error, show exact error message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[RHACS-RECONFIGURE]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-RECONFIGURE]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-RECONFIGURE] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-RECONFIGURE] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Prerequisites validation
log "========================================================="
log "RHACS Operator Cleanup Script"
log "========================================================="
log ""

log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Check if RHACS is already correctly installed - if so, skip to compliance step
log ""
log "Checking if RHACS is already correctly installed..."
RHACS_OPERATOR_NAMESPACE="rhacs-operator"
RHACS_INSTALLED=false

# Check if namespace exists
if oc get namespace "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    # Check if SecuredCluster CRD exists
    if oc get crd securedclusters.platform.stackrox.io &>/dev/null; then
        # Check if Central CRD exists
        if oc get crd centrals.platform.stackrox.io &>/dev/null; then
            # Check if SecuredCluster resource exists and is ready
            SECURED_CLUSTER_NAME=$(oc get securedcluster -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$SECURED_CLUSTER_NAME" ]; then
                # Check if SecuredCluster is not being deleted
                SC_DELETION_TIMESTAMP=$(oc get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")
                if [ -z "$SC_DELETION_TIMESTAMP" ]; then
                    # Check if SecuredCluster status indicates it's ready
                    SC_STATUS=$(oc get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
                    if [ "$SC_STATUS" = "True" ] || [ -n "$SC_STATUS" ]; then
                        # Check if Central resource exists
                        CENTRAL_NAME="rhacs-central-services"
                        if oc get central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
                            # Check if Central is not being deleted
                            CENTRAL_DELETION_TIMESTAMP=$(oc get central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")
                            if [ -z "$CENTRAL_DELETION_TIMESTAMP" ]; then
                                # Check if Central status indicates it's ready
                                CENTRAL_STATUS=$(oc get central "$CENTRAL_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
                                if [ "$CENTRAL_STATUS" = "True" ] || [ -n "$CENTRAL_STATUS" ]; then
                                    # Check if Central pods are running
                                    CENTRAL_PODS=$(oc get pods -n "$RHACS_OPERATOR_NAMESPACE" -l app=central -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
                                    if echo "$CENTRAL_PODS" | grep -q "Running"; then
                                        RHACS_INSTALLED=true
                                        log "✓ RHACS is correctly installed and ready:"
                                        log "  - Namespace '$RHACS_OPERATOR_NAMESPACE' exists"
                                        log "  - SecuredCluster CRD exists"
                                        log "  - SecuredCluster '$SECURED_CLUSTER_NAME' exists and is ready"
                                        log "  - Central CRD exists"
                                        log "  - Central '$CENTRAL_NAME' exists and is available"
                                        log "  - Central pods are running"
                                        log ""
                                        log "Skipping RHACS installation steps (01-06) and proceeding to compliance operator installation (step 07)"
                                        log "Exit code 10 indicates RHACS is already installed - master script will skip to step 07"
                                        exit 10
                                    fi
                                fi
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi
fi

if [ "$RHACS_INSTALLED" = false ]; then
    log "RHACS is not installed or not ready - proceeding with cleanup/installation"
    log ""
fi

# Check if we have cluster admin privileges
log "Checking cluster admin privileges..."
if ! oc auth can-i delete subscriptions --all-namespaces &>/dev/null; then
    error "Cluster admin privileges required to delete operators. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log ""

# Function to delete resources if they exist
delete_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local description="${4:-$resource_type/$resource_name}"
    
    if oc get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null; then
        log "Deleting $description in namespace $namespace..."
        if oc delete "$resource_type" "$resource_name" -n "$namespace" --timeout=60s &>/dev/null; then
            log "✓ Deleted $description"
            return 0
        else
            warning "Failed to delete $description (may already be deleting)"
            return 1
        fi
    else
        log "  $description not found in namespace $namespace (skipping)"
        return 0
    fi
}

# Function to delete all resources of a type in a namespace
delete_all_resources() {
    local resource_type=$1
    local namespace=$2
    local label_selector="${3:-}"
    
    local resources
    if [ -n "$label_selector" ]; then
        resources=$(oc get "$resource_type" -n "$namespace" -l "$label_selector" -o name 2>/dev/null || echo "")
    else
        resources=$(oc get "$resource_type" -n "$namespace" -o name 2>/dev/null || echo "")
    fi
    
    if [ -n "$resources" ]; then
        log "Found $(echo "$resources" | wc -l | tr -d '[:space:]') $resource_type resource(s) in namespace $namespace"
        for resource in $resources; do
            resource_name=$(echo "$resource" | cut -d'/' -f2)
            delete_resource "$resource_type" "$resource_name" "$namespace" "$resource"
        done
    else
        log "  No $resource_type resources found in namespace $namespace"
    fi
}

# Step 1: Find namespaces with RHACS/ACS resources (excluding rhacs-operator)
log "========================================================="
log "Step 1: Finding namespaces with RHACS/ACS resources"
log "========================================================="
log ""

CORRECT_NAMESPACE="rhacs-operator"

# Find all namespaces that contain RHACS/ACS resources
# Check for: operator subscriptions, Central resources, and SecuredCluster resources
RHACS_NAMESPACES=$(python3 << 'PYTHON_SCRIPT'
import sys
import json
import subprocess

correct_namespace = "rhacs-operator"
rhacs_namespaces = set()

# Check for operator subscriptions
try:
    result = subprocess.run(
        ["oc", "get", "subscriptions.operators.coreos.com", "--all-namespaces", "-o", "json"],
        capture_output=True,
        text=True,
        timeout=30
    )
    if result.returncode == 0:
        data = json.loads(result.stdout)
        for item in data.get('items', []):
            namespace = item.get('metadata', {}).get('namespace', '')
            package = item.get('spec', {}).get('name', '')
            if package in ['rhacs-operator', 'acs-operator'] and namespace:
                rhacs_namespaces.add(namespace)
except Exception:
    pass

# Check for Central resources
try:
    result = subprocess.run(
        ["oc", "get", "central.platform.stackrox.io", "--all-namespaces", "-o", "json"],
        capture_output=True,
        text=True,
        timeout=30
    )
    if result.returncode == 0:
        data = json.loads(result.stdout)
        for item in data.get('items', []):
            namespace = item.get('metadata', {}).get('namespace', '')
            if namespace:
                rhacs_namespaces.add(namespace)
except Exception:
    pass

# Check for SecuredCluster resources
try:
    result = subprocess.run(
        ["oc", "get", "securedcluster.platform.stackrox.io", "--all-namespaces", "-o", "json"],
        capture_output=True,
        text=True,
        timeout=30
    )
    if result.returncode == 0:
        data = json.loads(result.stdout)
        for item in data.get('items', []):
            namespace = item.get('metadata', {}).get('namespace', '')
            if namespace:
                rhacs_namespaces.add(namespace)
except Exception:
    pass

# Exclude the correct namespace
for ns in sorted(rhacs_namespaces):
    if ns.lower() != correct_namespace.lower():
        print(ns)
PYTHON_SCRIPT
)

# Handle empty result and convert to array
NAMESPACE_ARRAY=()
if [ -n "$RHACS_NAMESPACES" ]; then
    # Convert newline-separated string to array
    while IFS= read -r namespace; do
        if [ -n "$namespace" ]; then
            NAMESPACE_ARRAY+=("$namespace")
        fi
    done <<< "$RHACS_NAMESPACES"
fi

if [ ${#NAMESPACE_ARRAY[@]} -gt 0 ]; then
    log "Found namespaces with RHACS resources (excluding $CORRECT_NAMESPACE):"
    
    for namespace in "${NAMESPACE_ARRAY[@]}"; do
        if [ -n "$namespace" ]; then
            log "  - $namespace"
            # Show what resources are in this namespace
            CENTRAL_COUNT=$(oc get central.platform.stackrox.io -n "$namespace" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
            SECURED_COUNT=$(oc get securedcluster.platform.stackrox.io -n "$namespace" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
            SUB_COUNT=$(oc get subscriptions.operators.coreos.com -n "$namespace" --no-headers 2>/dev/null | grep -E "(rhacs-operator|acs-operator)" | wc -l | tr -d '[:space:]' || echo "0")
            if [ "$CENTRAL_COUNT" != "0" ] || [ "$SECURED_COUNT" != "0" ] || [ "$SUB_COUNT" != "0" ]; then
                log "    Resources: Central=$CENTRAL_COUNT, SecuredCluster=$SECURED_COUNT, Subscriptions=$SUB_COUNT"
            fi
        fi
    done
    log ""
    
    # Step 2: Delete RHACS resources in incorrect namespaces before deleting namespaces
    log "========================================================="
    log "Step 2: Deleting RHACS resources in incorrect namespaces"
    log "========================================================="
    log ""
    
    for namespace in "${NAMESPACE_ARRAY[@]}"; do
        if [ -n "$namespace" ] && [ "$namespace" != "$CORRECT_NAMESPACE" ]; then
            log "Deleting RHACS resources in namespace: $namespace"
            
            # Delete Central resources
            delete_all_resources "central.platform.stackrox.io" "$namespace"
            
            # Delete SecuredCluster resources
            delete_all_resources "securedcluster.platform.stackrox.io" "$namespace"
            
            # Delete operator subscriptions
            SUBSCRIPTIONS=$(oc get subscriptions.operators.coreos.com -n "$namespace" -o jsonpath='{.items[?(@.spec.name=="rhacs-operator" || @.spec.name=="acs-operator")].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$SUBSCRIPTIONS" ]; then
                for sub in $SUBSCRIPTIONS; do
                    delete_resource "subscription.operators.coreos.com" "$sub" "$namespace"
                done
            fi
            
            log ""
        fi
    done
    
    # Step 3: Delete the incorrect namespaces
    log "========================================================="
    log "Step 3: Deleting namespaces with RHACS resources"
    log "========================================================="
    log ""
    
    log "Note: '$CORRECT_NAMESPACE' is the correct namespace and will NOT be deleted"
    log ""
    
    for namespace in "${NAMESPACE_ARRAY[@]}"; do
        if [ -n "$namespace" ] && [ "$namespace" != "$CORRECT_NAMESPACE" ]; then
            log "Deleting namespace: $namespace"
            if oc delete namespace "$namespace" --timeout=120s &>/dev/null; then
                log "✓ Namespace $namespace deletion initiated"
            else
                warning "Failed to delete namespace $namespace (may already be deleting)"
            fi
        fi
    done
    
    log ""
    log "Waiting for namespace deletion(s) to complete..."
    sleep 15
    
    # Step 4: Verify deletion
    log "========================================================="
    log "Step 4: Verifying namespace deletion"
    log "========================================================="
    log ""
    
    for namespace in "${NAMESPACE_ARRAY[@]}"; do
        if [ -n "$namespace" ] && [ "$namespace" != "$CORRECT_NAMESPACE" ]; then
            if oc get namespace "$namespace" &>/dev/null 2>&1; then
                NS_PHASE=$(oc get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
                if [ "$NS_PHASE" = "Terminating" ]; then
                    log "  Namespace $namespace is still terminating (this is normal - deletion in progress)"
                else
                    warning "  Namespace $namespace still exists (phase: $NS_PHASE)"
                fi
            else
                log "✓ Namespace $namespace has been deleted"
            fi
        fi
    done
else
    log "No namespaces with RHACS resources found (excluding $CORRECT_NAMESPACE)"
    log "  (No cleanup needed)"
fi

log ""
log "========================================================="
log "✓ RHACS Operator cleanup completed!"
log "========================================================="
log ""
log "Summary:"
log "  - RHACS resources (Central, SecuredCluster, Subscriptions) deleted from incorrect namespaces"
log "  - Namespaces with RHACS resources (excluding $CORRECT_NAMESPACE) deleted"
log ""
log "Note: Namespace deletion may take a few minutes to complete"
log "      if there are finalizers. Resources will be removed"
log "      automatically once the namespace is fully deleted."
log ""

