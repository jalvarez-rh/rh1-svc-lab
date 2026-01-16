#!/bin/bash
# Red Hat Single Sign-On (RHSSO) / Keycloak Operator Uninstallation Script
# Removes the RHSSO Operator and all related resources

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
    echo -e "${GREEN}[RHSSO-UNINSTALL]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHSSO-UNINSTALL]${NC} $1"
}

error() {
    echo -e "${RED}[RHSSO-UNINSTALL] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHSSO-UNINSTALL] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Configuration
NAMESPACE="rhsso"
SUBSCRIPTION_NAME="rhsso-operator"
OPERATOR_GROUP_NAME="rhsso-operator-group"
CATALOG_SOURCE_NAME="rhsso-operator-catalogsource"

# Prerequisites validation
log "========================================================="
log "Red Hat Single Sign-On (RHSSO) Operator Uninstallation"
log "========================================================="
log ""

log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Check if we have cluster admin privileges
log "Checking cluster admin privileges..."
if ! oc auth can-i delete subscriptions --all-namespaces; then
    error "Cluster admin privileges required to uninstall operators. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log "Prerequisites validated successfully"
log ""

# Check if namespace exists
if ! oc get namespace $NAMESPACE >/dev/null 2>&1; then
    log "Namespace '$NAMESPACE' does not exist. Nothing to uninstall."
    log "Uninstallation complete."
    exit 0
fi

log "Found namespace '$NAMESPACE'. Proceeding with uninstallation..."
log ""

# Step 1: Delete Subscription (this will trigger CSV and InstallPlan deletion)
log "========================================================="
log "Step 1: Deleting Subscription"
log "========================================================="
log ""

if oc get subscription $SUBSCRIPTION_NAME -n $NAMESPACE >/dev/null 2>&1; then
    log "Deleting Subscription '$SUBSCRIPTION_NAME'..."
    
    # Delete the subscription
    if oc delete subscription $SUBSCRIPTION_NAME -n $NAMESPACE --ignore-not-found=true; then
        log "✓ Subscription deletion initiated"
    else
        warning "Failed to delete subscription (may already be deleted)"
    fi
    
    # Wait for subscription to be fully deleted
    log "Waiting for Subscription to be deleted..."
    MAX_WAIT=60
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        if ! oc get subscription $SUBSCRIPTION_NAME -n $NAMESPACE >/dev/null 2>&1; then
            log "✓ Subscription deleted"
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
    done
    
    if oc get subscription $SUBSCRIPTION_NAME -n $NAMESPACE >/dev/null 2>&1; then
        warning "Subscription still exists after ${MAX_WAIT} seconds. It may have finalizers."
    fi
else
    log "Subscription '$SUBSCRIPTION_NAME' not found (may already be deleted)"
fi

# Step 2: Delete CSV (ClusterServiceVersion)
log ""
log "========================================================="
log "Step 2: Deleting ClusterServiceVersion (CSV)"
log "========================================================="
log ""

CSV_NAME=$(oc get csv -n $NAMESPACE -o name 2>/dev/null | grep rhsso-operator | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")

if [ -n "$CSV_NAME" ]; then
    log "Found CSV: $CSV_NAME"
    log "Deleting CSV..."
    
    if oc delete csv "$CSV_NAME" -n $NAMESPACE --ignore-not-found=true; then
        log "✓ CSV deletion initiated"
    else
        warning "Failed to delete CSV (may already be deleted)"
    fi
    
    # Wait for CSV to be deleted
    log "Waiting for CSV to be deleted..."
    MAX_WAIT=60
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        if ! oc get csv "$CSV_NAME" -n $NAMESPACE >/dev/null 2>&1; then
            log "✓ CSV deleted"
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
    done
    
    if oc get csv "$CSV_NAME" -n $NAMESPACE >/dev/null 2>&1; then
        warning "CSV still exists after ${MAX_WAIT} seconds. It may have finalizers."
    fi
else
    log "No CSV found (may already be deleted)"
fi

# Step 3: Delete InstallPlan
log ""
log "========================================================="
log "Step 3: Deleting InstallPlan"
log "========================================================="
log ""

INSTALL_PLANS=$(oc get installplan -n $NAMESPACE -o name 2>/dev/null | grep -i rhsso || echo "")

if [ -n "$INSTALL_PLANS" ]; then
    log "Found InstallPlan(s), deleting..."
    echo "$INSTALL_PLANS" | while read -r installplan; do
        PLAN_NAME=$(echo "$installplan" | sed 's|installplan.operators.coreos.com/||')
        log "  Deleting InstallPlan: $PLAN_NAME"
        oc delete "$installplan" -n $NAMESPACE --ignore-not-found=true || warning "Failed to delete $PLAN_NAME"
    done
    log "✓ InstallPlan(s) deletion initiated"
else
    log "No InstallPlan found (may already be deleted)"
fi

# Step 4: Delete OperatorGroup
log ""
log "========================================================="
log "Step 4: Deleting OperatorGroup"
log "========================================================="
log ""

if oc get operatorgroup $OPERATOR_GROUP_NAME -n $NAMESPACE >/dev/null 2>&1; then
    log "Deleting OperatorGroup '$OPERATOR_GROUP_NAME'..."
    
    if oc delete operatorgroup $OPERATOR_GROUP_NAME -n $NAMESPACE --ignore-not-found=true; then
        log "✓ OperatorGroup deleted"
    else
        warning "Failed to delete OperatorGroup (may already be deleted)"
    fi
else
    log "OperatorGroup '$OPERATOR_GROUP_NAME' not found (may already be deleted)"
fi

# Step 5: Delete CatalogSource
log ""
log "========================================================="
log "Step 5: Deleting CatalogSource"
log "========================================================="
log ""

if oc get catalogsource $CATALOG_SOURCE_NAME -n $NAMESPACE >/dev/null 2>&1; then
    log "Deleting CatalogSource '$CATALOG_SOURCE_NAME'..."
    
    if oc delete catalogsource $CATALOG_SOURCE_NAME -n $NAMESPACE --ignore-not-found=true; then
        log "✓ CatalogSource deleted"
    else
        warning "Failed to delete CatalogSource (may already be deleted)"
    fi
else
    log "CatalogSource '$CATALOG_SOURCE_NAME' not found (may already be deleted or was not created by this script)"
fi

# Step 6: Delete any remaining operator resources
log ""
log "========================================================="
log "Step 6: Cleaning up remaining operator resources"
log "========================================================="
log ""

# Delete any remaining deployments, pods, etc. related to the operator
log "Checking for remaining operator pods..."
OPERATOR_PODS=$(oc get pods -n $NAMESPACE -l operators.coreos.com/rhsso-operator.rhsso -o name 2>/dev/null || echo "")

if [ -n "$OPERATOR_PODS" ]; then
    log "Found operator pods, deleting..."
    echo "$OPERATOR_PODS" | while read -r pod; do
        POD_NAME=$(echo "$pod" | sed 's|pod/||')
        log "  Deleting pod: $POD_NAME"
        oc delete "$pod" -n $NAMESPACE --ignore-not-found=true || warning "Failed to delete $POD_NAME"
    done
    log "✓ Operator pods deletion initiated"
else
    log "No operator pods found"
fi

# Step 7: Delete namespace (this will cascade delete remaining resources)
log ""
log "========================================================="
log "Step 7: Deleting namespace"
log "========================================================="
log ""

log "Deleting namespace '$NAMESPACE' (this will delete all remaining resources)..."
log "Warning: This will delete ALL resources in the namespace, including any Keycloak instances!"

# Check if there are any Keycloak CRs before deleting
KEYCLOAK_CRS=$(oc get keycloak -n $NAMESPACE -o name 2>/dev/null || echo "")
if [ -n "$KEYCLOAK_CRS" ]; then
    warning "Found Keycloak CR(s) in namespace:"
    echo "$KEYCLOAK_CRS" | while read -r cr; do
        warning "  - $cr"
    done
    warning "These will be deleted along with the namespace."
fi

# Delete the namespace
if oc delete namespace $NAMESPACE --ignore-not-found=true; then
    log "✓ Namespace deletion initiated"
else
    warning "Failed to delete namespace (may already be deleted)"
fi

# Wait for namespace to be fully deleted
log "Waiting for namespace to be deleted..."
MAX_WAIT=120
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if ! oc get namespace $NAMESPACE >/dev/null 2>&1; then
        log "✓ Namespace deleted"
        break
    fi
    if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting... (${WAIT_COUNT}s/${MAX_WAIT}s)"
        # Check if namespace is in Terminating state
        NAMESPACE_PHASE=$(oc get namespace $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$NAMESPACE_PHASE" = "Terminating" ]; then
            log "  Namespace is in Terminating state..."
        fi
    fi
    sleep 2
    WAIT_COUNT=$((WAIT_COUNT + 2))
done

if oc get namespace $NAMESPACE >/dev/null 2>&1; then
    warning "Namespace still exists after ${MAX_WAIT} seconds. It may have finalizers preventing deletion."
    warning "You may need to manually remove finalizers or wait longer."
    log ""
    log "To check namespace status: oc get namespace $NAMESPACE"
    log "To force delete (if stuck): oc delete namespace $NAMESPACE --force --grace-period=0"
else
    log "✓ Namespace fully deleted"
fi

# Final verification
log ""
log "========================================================="
log "Final verification"
log "========================================================="
log ""

# Check if namespace still exists
if oc get namespace $NAMESPACE >/dev/null 2>&1; then
    warning "Namespace '$NAMESPACE' still exists"
    log "Remaining resources:"
    oc get all -n $NAMESPACE 2>/dev/null || log "  (unable to list resources)"
else
    log "✓ Namespace '$NAMESPACE' does not exist"
fi

# Check for any remaining subscriptions, CSVs, or OperatorGroups
REMAINING_SUBS=$(oc get subscription -n $NAMESPACE 2>/dev/null | grep -i rhsso || echo "")
REMAINING_CSVS=$(oc get csv -n $NAMESPACE 2>/dev/null | grep -i rhsso || echo "")
REMAINING_OGS=$(oc get operatorgroup -n $NAMESPACE 2>/dev/null | grep -i rhsso || echo "")

if [ -n "$REMAINING_SUBS" ] || [ -n "$REMAINING_CSVS" ] || [ -n "$REMAINING_OGS" ]; then
    warning "Some resources may still exist:"
    [ -n "$REMAINING_SUBS" ] && warning "  Subscriptions: Found"
    [ -n "$REMAINING_CSVS" ] && warning "  CSVs: Found"
    [ -n "$REMAINING_OGS" ] && warning "  OperatorGroups: Found"
else
    log "✓ No remaining RHSSO operator resources found"
fi

log ""
log "========================================================="
log "RHSSO Operator uninstallation completed!"
log "========================================================="
log ""
log "Summary:"
log "  - Subscription: Deleted"
log "  - CSV: Deleted"
log "  - InstallPlan: Deleted"
log "  - OperatorGroup: Deleted"
log "  - CatalogSource: Deleted"
log "  - Namespace: Deleted"
log ""
log "Note: If any resources remain, they may have finalizers."
log "      You can check with: oc get all -n $NAMESPACE"
log ""
