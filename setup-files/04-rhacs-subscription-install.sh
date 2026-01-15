#!/bin/bash
# RHACS Central Installation Script
# Installs RHACS operator subscription in rhacs-operator namespace

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
    echo -e "${GREEN}[RHACS-INSTALL]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-INSTALL]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-INSTALL] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-INSTALL] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
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

# Check if we have cluster admin privileges
log "Checking cluster admin privileges..."
if ! oc auth can-i create subscriptions --all-namespaces &>/dev/null; then
    error "Cluster admin privileges required to install operators. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log "Prerequisites validated successfully"

# RHACS operator namespace
OPERATOR_NAMESPACE="rhacs-operator"

# Ensure namespace exists
log "Ensuring namespace '$OPERATOR_NAMESPACE' exists..."
if ! oc get namespace "$OPERATOR_NAMESPACE" &>/dev/null; then
    log "Creating namespace '$OPERATOR_NAMESPACE'..."
    oc create namespace "$OPERATOR_NAMESPACE" || error "Failed to create namespace"
fi
log "✓ Namespace '$OPERATOR_NAMESPACE' exists"

# Check if RHACS operator is already installed
log ""
log "Checking RHACS operator status"

OPERATOR_PACKAGE="rhacs-operator"
EXISTING_SUBSCRIPTION=false
NEEDS_CHANNEL_UPDATE=false

if oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    EXISTING_SUBSCRIPTION=true
    CURRENT_CSV=$(oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    EXISTING_CHANNEL=$(oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
    
    if [ -n "$CURRENT_CSV" ] && [ "$CURRENT_CSV" != "null" ]; then
        if oc get csv "$CURRENT_CSV" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            CSV_PHASE=$(oc get csv "$CURRENT_CSV" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "✓ RHACS operator is already installed and running"
                log "  Installed CSV: $CURRENT_CSV"
                log "  Current channel: ${EXISTING_CHANNEL:-unknown}"
                log "  Status: $CSV_PHASE"
                CSV_NAME="$CURRENT_CSV"
            else
                log "RHACS operator subscription exists but CSV is in phase: $CSV_PHASE"
            fi
        else
            log "RHACS operator subscription exists but CSV not found"
        fi
    else
        log "RHACS operator subscription exists but CSV not yet determined"
    fi
else
    log "RHACS operator not found, proceeding with installation..."
fi

# Determine preferred channel (rhacs-4.9, fallback to stable)
if [ "${NEEDS_INSTALL:-true}" = true ] || [ "$EXISTING_SUBSCRIPTION" = true ]; then
    # Determine channel
    log ""
    log "Determining available channel for RHACS operator..."
    
    CHANNEL=""
    if oc get packagemanifest "$OPERATOR_PACKAGE" -n openshift-marketplace >/dev/null 2>&1; then
        AVAILABLE_CHANNELS=$(oc get packagemanifest "$OPERATOR_PACKAGE" -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")
        
        if [ -n "$AVAILABLE_CHANNELS" ]; then
            log "Available channels: $AVAILABLE_CHANNELS"
            
            # Prefer stable channel, fall back to rhacs-4.9 if unavailable
            PREFERRED_CHANNELS=("stable" "rhacs-4.9")
            
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
        log "Using default channel: $CHANNEL (will fall back to rhacs-4.9 if unavailable)"
    fi
    
    # Create or update OperatorGroup (RHACS requires AllNamespaces mode)
    log ""
    log "Ensuring OperatorGroup exists with AllNamespaces mode..."
    
    EXISTING_OG=$(oc get operatorgroup -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    NEEDS_OG_UPDATE=false
    
    if [ -n "$EXISTING_OG" ]; then
        # Check if existing OperatorGroup uses AllNamespaces mode (empty targetNamespaces)
        OG_TARGET_NS=$(oc get operatorgroup "$EXISTING_OG" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.targetNamespaces[*]}' 2>/dev/null || echo "")
        if [ -n "$OG_TARGET_NS" ]; then
            log "  Existing OperatorGroup '$EXISTING_OG' uses single-namespace mode (targetNamespaces: $OG_TARGET_NS)"
            log "  RHACS operator requires AllNamespaces mode - updating OperatorGroup..."
            NEEDS_OG_UPDATE=true
        else
            log "✓ OperatorGroup '$EXISTING_OG' already uses AllNamespaces mode"
        fi
    else
        log "  No OperatorGroup found - creating new one with AllNamespaces mode..."
        NEEDS_OG_UPDATE=true
    fi
    
    if [ "$NEEDS_OG_UPDATE" = true ]; then
        # Delete existing OperatorGroup if it exists (to recreate with correct mode)
        if [ -n "$EXISTING_OG" ]; then
            log "  Deleting existing OperatorGroup '$EXISTING_OG'..."
            oc delete operatorgroup "$EXISTING_OG" -n "$OPERATOR_NAMESPACE" --timeout=60s &>/dev/null 2>&1 || warning "Failed to delete existing OperatorGroup (may already be deleting)"
            sleep 3  # Wait for deletion to complete
        fi
        
        # Create OperatorGroup with AllNamespaces mode (empty targetNamespaces array)
        log "  Creating OperatorGroup with AllNamespaces mode..."
        if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhacs-operator-group
  namespace: $OPERATOR_NAMESPACE
spec:
  targetNamespaces: []   # Empty array = AllNamespaces mode (required for RHACS)
EOF
        then
            error "Failed to create OperatorGroup"
        fi
        log "✓ OperatorGroup created with AllNamespaces mode"
        sleep 3  # Wait for OperatorGroup to be ready
    fi
    
    # Create or update Subscription
    log ""
    log "Creating/updating Subscription..."
    log "  Channel: $CHANNEL"
    log "  Source: redhat-operators"
    log "  SourceNamespace: openshift-marketplace"
    
    if [ "$EXISTING_SUBSCRIPTION" = true ]; then
        if [ "$EXISTING_CHANNEL" != "$CHANNEL" ]; then
            log "  Updating subscription channel from '$EXISTING_CHANNEL' to '$CHANNEL'..."
            oc patch subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" --type merge -p "{\"spec\":{\"channel\":\"$CHANNEL\"}}" || error "Failed to update subscription channel"
            log "✓ Subscription channel updated to $CHANNEL"
            log "  Waiting for operator upgrade to begin..."
            sleep 5
            NEEDS_CHANNEL_UPDATE=true
        else
            log "✓ Subscription already exists with channel: $CHANNEL"
        fi
    else
        log "  Creating new subscription..."
        if ! cat <<EOF | oc apply -f -
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
        then
            error "Failed to create Subscription"
        fi
        log "✓ Subscription created successfully"
        sleep 5  # Increased wait time for subscription to be processed
        
        # Check if InstallPlan needs approval (should be automatic, but check anyway)
        log "Checking InstallPlan status..."
        # Wait a moment for InstallPlan to be created
        sleep 3
        
        # Find InstallPlan related to this subscription
        INSTALL_PLAN=$(oc get installplan -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | head -1 || echo "")
        
        if [ -n "$INSTALL_PLAN" ]; then
            IP_APPROVAL=$(oc get installplan "$INSTALL_PLAN" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.approval}' 2>/dev/null || echo "")
            IP_PHASE=$(oc get installplan "$INSTALL_PLAN" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            IP_APPROVED=$(oc get installplan "$INSTALL_PLAN" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.approved}' 2>/dev/null || echo "")
            log "  Found InstallPlan: $INSTALL_PLAN (approval: ${IP_APPROVAL:-unknown}, phase: ${IP_PHASE:-unknown}, approved: ${IP_APPROVED:-unknown})"
            
            # If InstallPlan is Manual and not approved, approve it
            if [ "$IP_APPROVAL" = "Manual" ] && [ "$IP_APPROVED" != "true" ] && [ "$IP_PHASE" != "Complete" ]; then
                log "  Approving Manual InstallPlan..."
                oc patch installplan "$INSTALL_PLAN" -n "$OPERATOR_NAMESPACE" --type merge -p '{"spec":{"approved":true}}' || warning "Failed to approve InstallPlan"
                log "  ✓ InstallPlan approved"
            fi
        else
            log "  InstallPlan not found yet (will check during CSV wait)"
        fi
    fi
    
    # Wait for CSV to be created
    log ""
    log "Waiting for ClusterServiceVersion to be created..."
    MAX_WAIT=180  # Increased timeout to 180 seconds
    WAIT_COUNT=0
    CSV_CREATED=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        # Check if CSV exists
        if oc get csv -n "$OPERATOR_NAMESPACE" 2>/dev/null | grep -q "$OPERATOR_PACKAGE"; then
            CSV_CREATED=true
            log "✓ CSV created"
            break
        fi
        
        # Show progress every 15 seconds with detailed status
        if [ $((WAIT_COUNT % 15)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            log "  Progress check (${WAIT_COUNT}s/${MAX_WAIT}s):"
            
            # Check subscription status
            SUB_STATUS=$(oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
            SUB_CONDITION=$(oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || echo "")
            log "    Subscription state: ${SUB_STATUS}"
            if [ -n "$SUB_CONDITION" ] && [ "$SUB_CONDITION" != "null" ]; then
                log "    Subscription condition: ${SUB_CONDITION}"
            fi
            
            # Check InstallPlan status
            INSTALL_PLAN=$(oc get installplan -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | head -1 || echo "")
            if [ -n "$INSTALL_PLAN" ]; then
                IP_PHASE=$(oc get installplan "$INSTALL_PLAN" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
                IP_APPROVAL=$(oc get installplan "$INSTALL_PLAN" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.approval}' 2>/dev/null || echo "unknown")
                IP_APPROVED=$(oc get installplan "$INSTALL_PLAN" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.approved}' 2>/dev/null || echo "unknown")
                log "    InstallPlan: $INSTALL_PLAN (phase: $IP_PHASE, approval: $IP_APPROVAL, approved: $IP_APPROVED)"
                
                # If InstallPlan is Manual and not approved, try to approve it
                if [ "$IP_APPROVAL" = "Manual" ] && [ "$IP_APPROVED" != "true" ] && [ "$IP_PHASE" != "Complete" ]; then
                    log "    Attempting to approve Manual InstallPlan..."
                    oc patch installplan "$INSTALL_PLAN" -n "$OPERATOR_NAMESPACE" --type merge -p '{"spec":{"approved":true}}' 2>/dev/null && log "      ✓ InstallPlan approved" || warning "      Failed to approve InstallPlan"
                fi
            else
                log "    InstallPlan: Not found yet"
            fi
            
            # Check for any CSV
            CSV_COUNT=$(oc get csv -n "$OPERATOR_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
            log "    CSV count in namespace: $CSV_COUNT"
            log ""
        fi
        
        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done
    
    if [ "$CSV_CREATED" = false ]; then
        warning "CSV not created after ${MAX_WAIT} seconds."
        log ""
        log "Current subscription status:"
        oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o yaml 2>/dev/null | grep -A 20 "status:" || true
        log ""
        log "InstallPlan status:"
        oc get installplan -n "$OPERATOR_NAMESPACE" -o yaml 2>/dev/null | grep -A 10 "metadata:\|spec:\|status:" || true
        log ""
        log "For more details, run:"
        log "  oc describe subscription $OPERATOR_PACKAGE -n $OPERATOR_NAMESPACE"
        log "  oc get installplan -n $OPERATOR_NAMESPACE"
        log "  oc get csv -n $OPERATOR_NAMESPACE"
        error "CSV not created. Check the status above for details."
    fi
    
    # Get the CSV name
    CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null | grep "$OPERATOR_PACKAGE" | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -l operators.coreos.com/$OPERATOR_PACKAGE.$OPERATOR_NAMESPACE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    if [ -z "$CSV_NAME" ]; then
        error "Failed to find CSV name for $OPERATOR_PACKAGE"
    fi
    log "Found CSV: $CSV_NAME"
    
    # Wait for CSV to be in Succeeded phase
    log ""
    if [ "$NEEDS_CHANNEL_UPDATE" = true ]; then
        log "Waiting for operator upgrade to complete (channel change: $EXISTING_CHANNEL -> $CHANNEL)..."
        # Wait a bit longer for upgrades
        CSV_UPGRADE_TIMEOUT=600
    else
        log "Waiting for ClusterServiceVersion to be installed..."
        CSV_UPGRADE_TIMEOUT=300
    fi
    
    if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n "$OPERATOR_NAMESPACE" --timeout=${CSV_UPGRADE_TIMEOUT}s 2>/dev/null; then
        CSV_STATUS=$(oc get csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        warning "CSV did not reach Succeeded phase within timeout. Current status: $CSV_STATUS"
        log "Checking CSV details..."
        oc get csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE"
        log "Check CSV details: oc describe csv $CSV_NAME -n $OPERATOR_NAMESPACE"
        
        # If channel was updated, check if a new CSV is being installed
        if [ "$NEEDS_CHANNEL_UPDATE" = true ]; then
            NEW_CSV=$(oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
            if [ -n "$NEW_CSV" ] && [ "$NEW_CSV" != "$CSV_NAME" ]; then
                log "New CSV detected: $NEW_CSV (upgrade in progress)"
                log "Waiting for new CSV to be ready..."
                if oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$NEW_CSV" -n "$OPERATOR_NAMESPACE" --timeout=300s 2>/dev/null; then
                    CSV_NAME="$NEW_CSV"
                    log "✓ Operator upgraded successfully to $NEW_CSV"
                else
                    warning "New CSV $NEW_CSV did not reach Succeeded phase within timeout"
                fi
            fi
        fi
    else
        if [ "$NEEDS_CHANNEL_UPDATE" = true ]; then
            log "✓ Operator upgraded successfully (channel: $CHANNEL)"
        else
            log "✓ CSV is in Succeeded phase"
        fi
    fi
fi

log ""
log "========================================================="
log "RHACS Operator Installation Completed!"
log "========================================================="
log "Operator Namespace: $OPERATOR_NAMESPACE"
log "Operator: $OPERATOR_PACKAGE"
if [ -n "${CSV_NAME:-}" ] && [ "$CSV_NAME" != "null" ]; then
    log "CSV: $CSV_NAME"
fi
if [ -n "${CHANNEL:-}" ] && [ "$CHANNEL" != "null" ]; then
    log "Channel: ${CHANNEL}"
fi
log "========================================================="
log ""
log "RHACS operator is installed and ready."
log "Next step: Create Central resource to deploy RHACS Central."
log ""

