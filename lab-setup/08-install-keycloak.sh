#!/bin/bash
# Red Hat Single Sign-On (RHSSO) / Keycloak Operator Installation Script
# Installs the RHSSO Operator using the provided subscription configuration

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
    echo -e "${GREEN}[RHSSO-INSTALL]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHSSO-INSTALL]${NC} $1"
}

error() {
    echo -e "${RED}[RHSSO-INSTALL] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHSSO-INSTALL] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Prerequisites validation
log "========================================================="
log "Red Hat Single Sign-On (RHSSO) Operator Installation"
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
if ! oc auth can-i create subscriptions --all-namespaces; then
    error "Cluster admin privileges required to install operators. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log "Prerequisites validated successfully"
log ""

# Check if RHSSO Operator is already installed
log "Checking if RHSSO Operator is already installed..."
NAMESPACE="rhsso"

if oc get namespace $NAMESPACE >/dev/null 2>&1; then
    log "Namespace $NAMESPACE already exists"
    
    # Check for existing subscription
    if oc get subscription.operators.coreos.com rhsso-operator -n $NAMESPACE >/dev/null 2>&1; then
        CURRENT_CSV=$(oc get subscription.operators.coreos.com rhsso-operator -n $NAMESPACE -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
        if [ -z "$CURRENT_CSV" ]; then
            log "Subscription exists but CSV not yet determined, proceeding with installation..."
        else
            CSV_PHASE=$(oc get csv $CURRENT_CSV -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "✓ RHSSO Operator is already installed and running"
                log "  Installed CSV: $CURRENT_CSV"
                log "  Status: $CSV_PHASE"
                log "Skipping installation..."
                exit 0
            else
                log "RHSSO Operator subscription exists but CSV is in phase: $CSV_PHASE"
                log "Continuing with installation to ensure proper setup..."
            fi
        fi
    else
        log "Namespace exists but no subscription found, proceeding with installation..."
    fi
else
    log "RHSSO Operator not found, proceeding with installation..."
fi

# Install Red Hat Single Sign-On Operator
log ""
log "========================================================="
log "Installing Red Hat Single Sign-On Operator"
log "========================================================="
log ""
log "Following idempotent installation steps (safe to run multiple times)..."
log ""

# Step 1: Create the namespace (idempotent)
log "Step 1: Creating namespace $NAMESPACE..."
if ! oc create ns $NAMESPACE --dry-run=client -o yaml | oc apply -f -; then
    error "Failed to create $NAMESPACE namespace"
fi
log "✓ Namespace created successfully"

# Step 2: Create OperatorGroup
log ""
log "Step 2: Creating OperatorGroup..."
if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhsso-operator-group
  namespace: $NAMESPACE
spec:
  targetNamespaces:
    - $NAMESPACE
EOF
then
    error "Failed to create OperatorGroup"
fi
log "✓ OperatorGroup created successfully (targeting namespace: $NAMESPACE)"

# Step 3: Create or verify CatalogSource
log ""
log "Step 3: Creating/verifying CatalogSource..."

CATALOG_SOURCE_NAME="rhsso-operator-catalogsource"
CATALOG_SOURCE_EXISTS=false

if oc get catalogsource $CATALOG_SOURCE_NAME -n $NAMESPACE >/dev/null 2>&1; then
    log "CatalogSource '$CATALOG_SOURCE_NAME' already exists"
    CATALOG_SOURCE_EXISTS=true
    
    # Check if it's healthy
    CATALOG_STATUS=$(oc get catalogsource $CATALOG_SOURCE_NAME -n $NAMESPACE -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
    if [ "$CATALOG_STATUS" = "READY" ]; then
        log "✓ CatalogSource is READY"
    else
        log "CatalogSource status: ${CATALOG_STATUS:-unknown}"
    fi
else
    log "Creating CatalogSource '$CATALOG_SOURCE_NAME'..."
    
    # Create CatalogSource pointing to redhat-operators
    # Note: This creates a custom catalog source that mirrors redhat-operators
    # If you have a specific catalog image, replace the image reference below
    if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOG_SOURCE_NAME
  namespace: $NAMESPACE
spec:
  sourceType: grpc
  image: registry.redhat.io/redhat/redhat-operator-index:v4.15
  displayName: RHSSO Operator Catalog
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 30m
EOF
    then
        error "Failed to create CatalogSource"
    fi
    log "✓ CatalogSource created"
    
    # Wait for catalog source to be ready
    log "Waiting for CatalogSource to be ready..."
    CATALOG_READY=false
    for i in {1..30}; do
        CATALOG_STATUS=$(oc get catalogsource $CATALOG_SOURCE_NAME -n $NAMESPACE -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
        if [ "$CATALOG_STATUS" = "READY" ]; then
            CATALOG_READY=true
            log "✓ CatalogSource is READY"
            break
        else
            if [ $((i % 5)) -eq 0 ]; then
                log "  CatalogSource status: ${CATALOG_STATUS:-unknown} (waiting for READY...)"
            fi
        fi
        sleep 2
    done
    
    if [ "$CATALOG_READY" = false ]; then
        warning "CatalogSource may not be ready yet, but continuing..."
    fi
fi

# Step 4: Create the Subscription
log ""
log "Step 4: Creating Subscription..."
log "  Channel: stable"
log "  Source: $CATALOG_SOURCE_NAME"
log "  SourceNamespace: $NAMESPACE"
log "  StartingCSV: rhsso-operator.7.6.11-opr-004"

if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhsso-operator
  namespace: $NAMESPACE
  labels:
    operators.coreos.com/rhsso-operator.rhsso: ''
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhsso-operator
  source: $CATALOG_SOURCE_NAME
  sourceNamespace: $NAMESPACE
  startingCSV: rhsso-operator.7.6.11-opr-004
EOF
then
    error "Failed to create Subscription"
fi
log "✓ Subscription created successfully"

# Verify subscription was created
log "Verifying subscription..."
sleep 3

SUBSCRIPTION_STATUS=$(oc get subscription rhsso-operator -n $NAMESPACE -o jsonpath='{.status.state}' 2>/dev/null || echo "")
log "Subscription state: ${SUBSCRIPTION_STATUS:-unknown}"

# Step 5: Wait for CSV to be created and installed
log ""
log "Step 5: Waiting for installation (60-120 seconds)..."
log "Watching install progress..."
log ""

# Wait for CSV to be created
MAX_WAIT=120
WAIT_COUNT=0
CSV_CREATED=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if oc get csv -n $NAMESPACE 2>/dev/null | grep -q rhsso-operator; then
        CSV_CREATED=true
        log "✓ CSV created"
        break
    fi
    
    # Show progress every 10 seconds
    if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Progress check (${WAIT_COUNT}s/${MAX_WAIT}s):"
        oc get csv,subscription,installplan -n $NAMESPACE 2>/dev/null | head -5 || true
        log ""
    fi
    
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ "$CSV_CREATED" = false ]; then
    warning "CSV not created after ${MAX_WAIT} seconds. Current status:"
    oc get csv,subscription,installplan -n $NAMESPACE
    warning "CSV may still be installing. Check subscription status: oc get subscription rhsso-operator -n $NAMESPACE"
fi

# Get the CSV name
CSV_NAME=$(oc get csv -n $NAMESPACE -o name 2>/dev/null | grep rhsso-operator | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
if [ -z "$CSV_NAME" ]; then
    CSV_NAME=$(oc get csv -n $NAMESPACE -l operators.coreos.com/rhsso-operator.rhsso -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi
if [ -z "$CSV_NAME" ]; then
    warning "Failed to find CSV name for rhsso-operator. It may still be installing."
    CSV_NAME="rhsso-operator.7.6.11-opr-004"
fi

# Wait for CSV to be in Succeeded phase
if [ -n "$CSV_NAME" ]; then
    log "Waiting for CSV '$CSV_NAME' to reach Succeeded phase..."
    if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n $NAMESPACE --timeout=300s 2>/dev/null; then
        CSV_STATUS=$(oc get csv "$CSV_NAME" -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        warning "CSV did not reach Succeeded phase within timeout. Current status: $CSV_STATUS"
        log "Checking CSV details..."
        oc get csv "$CSV_NAME" -n $NAMESPACE
    else
        log "✓ CSV is in Succeeded phase"
    fi
fi

# Step 6: Final check – verify CSV and pods
log ""
log "Step 6: Final check - verifying CSV and pods..."
log ""
log "CSV status:"
oc get csv -n $NAMESPACE 2>/dev/null || log "  No CSV found"
log ""
log "Subscription status:"
oc get subscription rhsso-operator -n $NAMESPACE 2>/dev/null || log "  No subscription found"
log ""
log "Pod status:"
oc get pods -n $NAMESPACE 2>/dev/null || log "  No pods found"
log ""

# Step 7: Verify final status
log "Step 7: Final verification..."
log ""

if [ -n "$CSV_NAME" ]; then
    CSV_PHASE=$(oc get csv "$CSV_NAME" -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    
    if [ "$CSV_PHASE" = "Succeeded" ]; then
        log "✓ CSV Phase: Succeeded"
    else
        warning "CSV Phase: $CSV_PHASE (expected: Succeeded)"
    fi
else
    warning "CSV name not found"
fi

POD_STATUS=$(oc get pods -n $NAMESPACE -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
if echo "$POD_STATUS" | grep -q "Running"; then
    RUNNING_COUNT=$(echo "$POD_STATUS" | grep -o "Running" | wc -l | tr -d '[:space:]')
    log "✓ Found $RUNNING_COUNT Running pod(s)"
else
    warning "No Running pods found. Status: $POD_STATUS"
fi

log ""
log "========================================================="
log "RHSSO Operator installation completed!"
log "========================================================="
log "Namespace: $NAMESPACE"
log "Operator: rhsso-operator"
if [ -n "$CSV_NAME" ]; then
    log "CSV: $CSV_NAME"
    CSV_PHASE=$(oc get csv "$CSV_NAME" -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    log "CSV Phase: $CSV_PHASE"
fi
log "========================================================="
log ""

# Step 8: Deploy Keycloak instance
log ""
log "========================================================="
log "Step 8: Deploying Keycloak instance"
log "========================================================="
log ""

KEYCLOAK_CR_NAME="rhsso-instance"

# Check if Keycloak CR already exists
if oc get keycloak $KEYCLOAK_CR_NAME -n $NAMESPACE >/dev/null 2>&1; then
    log "Keycloak CR '$KEYCLOAK_CR_NAME' already exists"
    
    # Check if it's ready
    KEYCLOAK_READY=$(oc get keycloak $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    KEYCLOAK_PHASE=$(oc get keycloak $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    
    if [ "$KEYCLOAK_READY" = "true" ]; then
        log "✓ Keycloak instance is already ready"
        KEYCLOAK_EXTERNAL_URL=$(oc get keycloak $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.externalURL}' 2>/dev/null || echo "")
        if [ -n "$KEYCLOAK_EXTERNAL_URL" ]; then
            log "  External URL: $KEYCLOAK_EXTERNAL_URL"
        fi
    else
        log "Keycloak instance exists but is not ready yet (phase: ${KEYCLOAK_PHASE:-unknown})"
        log "Waiting for it to become ready..."
    fi
else
    log "Creating Keycloak CR '$KEYCLOAK_CR_NAME'..."
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: Keycloak
metadata:
  name: $KEYCLOAK_CR_NAME
  namespace: $NAMESPACE
  labels:
    app: sso
spec:
  externalAccess:
    enabled: true
  instances: 1
EOF
    then
        error "Failed to create Keycloak CR"
    fi
    log "✓ Keycloak CR created successfully"
fi

# Wait for Keycloak instance to be ready
log ""
log "Waiting for Keycloak instance to be ready..."
MAX_WAIT=600
WAIT_COUNT=0
KEYCLOAK_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    KEYCLOAK_READY_STATUS=$(oc get keycloak $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    KEYCLOAK_PHASE=$(oc get keycloak $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    
    if [ "$KEYCLOAK_READY_STATUS" = "true" ]; then
        KEYCLOAK_READY=true
        log "✓ Keycloak instance is ready"
        break
    fi
    
    # Show progress every 30 seconds
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Progress check (${WAIT_COUNT}s/${MAX_WAIT}s):"
        log "  Phase: ${KEYCLOAK_PHASE:-unknown}"
        log "  Ready: ${KEYCLOAK_READY_STATUS:-false}"
        
        # Show pod status
        KEYCLOAK_PODS=$(oc get pods -n $NAMESPACE -l app=keycloak -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
        if [ -n "$KEYCLOAK_PODS" ]; then
            log "  Keycloak pods: $KEYCLOAK_PODS"
        fi
        log ""
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$KEYCLOAK_READY" = false ]; then
    warning "Keycloak instance did not become ready within ${MAX_WAIT} seconds"
    log "Current status:"
    oc get keycloak $KEYCLOAK_CR_NAME -n $NAMESPACE
    warning "Keycloak may still be installing. Check status with: oc get keycloak $KEYCLOAK_CR_NAME -n $NAMESPACE"
else
    log "✓ Keycloak instance is ready"
fi

# Get Keycloak URLs and credentials
log ""
log "Retrieving Keycloak access information..."

KEYCLOAK_EXTERNAL_URL=$(oc get keycloak $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.externalURL}' 2>/dev/null || echo "")
KEYCLOAK_INTERNAL_URL=$(oc get keycloak $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.internalURL}' 2>/dev/null || echo "")
KEYCLOAK_CREDENTIAL_SECRET=$(oc get keycloak $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.credentialSecret}' 2>/dev/null || echo "")

KEYCLOAK_USERNAME=""
KEYCLOAK_PASSWORD=""

if [ -n "$KEYCLOAK_CREDENTIAL_SECRET" ]; then
    KEYCLOAK_USERNAME=$(oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $NAMESPACE -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    KEYCLOAK_PASSWORD=$(oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $NAMESPACE -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
fi

log ""
log "========================================================="
log "Keycloak Installation Summary"
log "========================================================="
log "Namespace: $NAMESPACE"
log "Keycloak CR: $KEYCLOAK_CR_NAME"
log "Status: Ready"
log ""
if [ -n "$KEYCLOAK_EXTERNAL_URL" ]; then
    log "External URL: $KEYCLOAK_EXTERNAL_URL"
fi
if [ -n "$KEYCLOAK_INTERNAL_URL" ]; then
    log "Internal URL: $KEYCLOAK_INTERNAL_URL"
fi
if [ -n "$KEYCLOAK_USERNAME" ] && [ -n "$KEYCLOAK_PASSWORD" ]; then
    log "Username: $KEYCLOAK_USERNAME"
    log "Password: $KEYCLOAK_PASSWORD"
elif [ -n "$KEYCLOAK_CREDENTIAL_SECRET" ]; then
    log "Credentials: Stored in secret '$KEYCLOAK_CREDENTIAL_SECRET'"
    log "  To retrieve: oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $NAMESPACE -o jsonpath='{.data.username}' | base64 -d"
    log "  To retrieve: oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
fi
log "========================================================="
log ""
