#!/bin/bash
# Trusted Artifact Signer Installation Script
# Installs Trusted Artifact Signer operator and creates TrustedArtifactSigner CR in tssc namespace

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
    echo -e "${GREEN}[TAS-INSTALL]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[TAS-INSTALL]${NC} $1"
}

error() {
    echo -e "${RED}[TAS-INSTALL] ERROR:${NC} $1" >&2
    echo -e "${RED}[TAS-INSTALL] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Prerequisites validation
log "========================================================="
log "Trusted Artifact Signer Installation"
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

# Trusted Artifact Signer operator namespace
OPERATOR_NAMESPACE="tssc"

# Ensure namespace exists
log "Ensuring namespace '$OPERATOR_NAMESPACE' exists..."
if ! oc get namespace "$OPERATOR_NAMESPACE" &>/dev/null; then
    log "Creating namespace '$OPERATOR_NAMESPACE'..."
    oc create namespace "$OPERATOR_NAMESPACE" || error "Failed to create namespace"
fi
log "✓ Namespace '$OPERATOR_NAMESPACE' exists"

# Check if Trusted Artifact Signer operator is already installed
log ""
log "Checking Trusted Artifact Signer operator status"

OPERATOR_PACKAGE="trusted-artifact-signer-operator"
EXISTING_SUBSCRIPTION=false

if oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    EXISTING_SUBSCRIPTION=true
    CURRENT_CSV=$(oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    EXISTING_CHANNEL=$(oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
    
    if [ -n "$CURRENT_CSV" ] && [ "$CURRENT_CSV" != "null" ]; then
        if oc get csv "$CURRENT_CSV" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            CSV_PHASE=$(oc get csv "$CURRENT_CSV" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "✓ Trusted Artifact Signer operator is already installed and running"
                log "  Installed CSV: $CURRENT_CSV"
                log "  Current channel: ${EXISTING_CHANNEL:-unknown}"
                log "  Status: $CSV_PHASE"
            else
                log "Trusted Artifact Signer operator subscription exists but CSV is in phase: $CSV_PHASE"
            fi
        else
            log "Trusted Artifact Signer operator subscription exists but CSV not found"
        fi
    else
        log "Trusted Artifact Signer operator subscription exists but CSV not yet determined"
    fi
else
    log "Trusted Artifact Signer operator not found, proceeding with installation..."
fi

# Determine preferred channel
log ""
log "Determining available channel for Trusted Artifact Signer operator..."

CHANNEL=""
if oc get packagemanifest "$OPERATOR_PACKAGE" -n openshift-marketplace >/dev/null 2>&1; then
    AVAILABLE_CHANNELS=$(oc get packagemanifest "$OPERATOR_PACKAGE" -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")
    
    if [ -n "$AVAILABLE_CHANNELS" ]; then
        log "Available channels: $AVAILABLE_CHANNELS"
        
        # Prefer stable channel
        PREFERRED_CHANNELS=("stable" "release-1.0")
        
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
  name: tssc-operatorgroup
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
log "Waiting for operator CSV to be created..."
MAX_WAIT=300
WAIT_COUNT=0
CSV_CREATED=false
CSV_READY=false

# First wait for CSV to be created
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Try multiple ways to find the CSV
    CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Trusted Artifact Signer Operator")].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[?(@.metadata.name=~"trusted-artifact-signer.*")].metadata.name}' 2>/dev/null | head -1 || echo "")
    fi
    
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null | grep -i trusted | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    fi
    
    if [ -z "$CSV_NAME" ]; then
        # Check if any CSV exists at all
        CSV_COUNT=$(oc get csv -n "$OPERATOR_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
        if [ "$CSV_COUNT" -gt 0 ]; then
            CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        fi
    fi
    
    if [ -n "$CSV_NAME" ]; then
        CSV_CREATED=true
        log "✓ CSV found: $CSV_NAME"
        break
    fi
    
    # Check subscription status for debugging
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting for CSV... (${WAIT_COUNT}s/${MAX_WAIT}s)"
        
        # Show subscription status
        SUB_STATE=$(oc get subscription "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
        SUB_CONDITION=$(oc get subscription "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || echo "")
        log "    Subscription state: ${SUB_STATE}"
        if [ -n "$SUB_CONDITION" ] && [ "$SUB_CONDITION" != "null" ]; then
            log "    Subscription condition: ${SUB_CONDITION}"
        fi
        
        # Check InstallPlan
        INSTALL_PLAN=$(oc get installplan -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | head -1 || echo "")
        if [ -n "$INSTALL_PLAN" ]; then
            IP_PHASE=$(oc get installplan "$INSTALL_PLAN" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
            log "    InstallPlan: $INSTALL_PLAN (phase: $IP_PHASE)"
        fi
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$CSV_CREATED" = false ]; then
    log ""
    log "CSV not found. Current status:"
    oc get subscription "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o yaml || true
    oc get installplan -n "$OPERATOR_NAMESPACE" || true
    oc get csv -n "$OPERATOR_NAMESPACE" || true
    error "CSV was not created within ${MAX_WAIT} seconds. Check subscription and installplan status above."
fi

# Now wait for CSV to be in Succeeded phase
log ""
log "Waiting for CSV '$CSV_NAME' to reach Succeeded phase..."
MAX_WAIT=600
WAIT_COUNT=0

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    
    if [ "$CSV_PHASE" = "Succeeded" ]; then
        CSV_READY=true
        log "✓ CSV is ready: $CSV_NAME"
        break
    fi
    
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting... (${WAIT_COUNT}s/${MAX_WAIT}s)"
        log "  CSV phase: ${CSV_PHASE:-Unknown}"
        
        # Show CSV conditions for debugging
        CSV_CONDITIONS=$(oc get csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE" -o jsonpath='{range .status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}' 2>/dev/null || echo "")
        if [ -n "$CSV_CONDITIONS" ]; then
            log "  CSV conditions:"
            echo "$CSV_CONDITIONS" | while read -r line; do
                log "    $line"
            done
        fi
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$CSV_READY" = false ]; then
    log ""
    log "CSV did not reach Succeeded phase. Current status:"
    oc get csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE" -o yaml || true
    error "CSV did not become ready within ${MAX_WAIT} seconds. Check CSV status above."
fi

# Check if TrustedArtifactSigner CR already exists
log ""
log "Checking for existing TrustedArtifactSigner CR..."

TAS_CR_NAME="trusted-artifact-signer"
if oc get trustedartifactsigner "$TAS_CR_NAME" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    log "✓ TrustedArtifactSigner CR '$TAS_CR_NAME' already exists"
    
    # Check status
    TAS_STATUS=$(oc get trustedartifactsigner "$TAS_CR_NAME" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$TAS_STATUS" = "True" ]; then
        log "✓ TrustedArtifactSigner is Ready"
        log ""
        log "========================================================="
        log "Trusted Artifact Signer Installation Completed!"
        log "========================================================="
        log "Namespace: $OPERATOR_NAMESPACE"
        log "TrustedArtifactSigner CR: $TAS_CR_NAME"
        log "Status: Ready"
        log "========================================================="
        exit 0
    else
        log "TrustedArtifactSigner exists but status is: ${TAS_STATUS:-Unknown}"
        log "Waiting for it to become ready..."
    fi
else
    log "Creating TrustedArtifactSigner CR..."
    
    # Create TrustedArtifactSigner CR
    cat <<EOF | oc apply -f -
apiVersion: tssc.redhat.com/v1alpha1
kind: TrustedArtifactSigner
metadata:
  name: $TAS_CR_NAME
  namespace: $OPERATOR_NAMESPACE
spec: {}
EOF
    log "✓ TrustedArtifactSigner CR created"
fi

# Wait for TrustedArtifactSigner to be ready
log ""
log "Waiting for TrustedArtifactSigner to become ready..."
MAX_WAIT=600
WAIT_COUNT=0
TAS_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    TAS_STATUS=$(oc get trustedartifactsigner "$TAS_CR_NAME" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    
    if [ "$TAS_STATUS" = "True" ]; then
        TAS_READY=true
        log "✓ TrustedArtifactSigner is Ready"
        break
    fi
    
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting... (${WAIT_COUNT}s/${MAX_WAIT}s)"
        log "  Current status: ${TAS_STATUS:-Unknown}"
        
        # Show component status
        log "  Component status:"
        oc get trustedartifactsigner "$TAS_CR_NAME" -n "$OPERATOR_NAMESPACE" -o jsonpath='{range .status.conditions[*]}{.type}: {.status}{"\n"}{end}' 2>/dev/null || true
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$TAS_READY" = false ]; then
    warning "TrustedArtifactSigner did not become ready within ${MAX_WAIT} seconds"
    log "Current status:"
    oc get trustedartifactsigner "$TAS_CR_NAME" -n "$OPERATOR_NAMESPACE" -o yaml
    error "TrustedArtifactSigner is not ready. Check operator logs for details."
fi

# Get component URLs
log ""
log "Retrieving Trusted Artifact Signer component URLs..."

FULCIO_URL=$(oc get fulcio -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].status.url}' 2>/dev/null || echo "")
REKOR_URL=$(oc get rekor -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].status.url}' 2>/dev/null || echo "")
TUF_URL=$(oc get tuf -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].status.url}' 2>/dev/null || echo "")
CLIENT_SERVER_ROUTE=$(oc get route -l app.kubernetes.io/component=client-server -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

log ""
log "========================================================="
log "Trusted Artifact Signer Installation Completed!"
log "========================================================="
log "Namespace: $OPERATOR_NAMESPACE"
log "TrustedArtifactSigner CR: $TAS_CR_NAME"
log "Status: Ready"
if [ -n "$FULCIO_URL" ]; then
    log "Fulcio URL: $FULCIO_URL"
fi
if [ -n "$REKOR_URL" ]; then
    log "Rekor URL: $REKOR_URL"
fi
if [ -n "$TUF_URL" ]; then
    log "TUF URL: $TUF_URL"
fi
if [ -n "$CLIENT_SERVER_ROUTE" ]; then
    log "Client Server Route: https://$CLIENT_SERVER_ROUTE"
fi
log "========================================================="
log ""
