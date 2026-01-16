#!/bin/bash
# Keycloak Installation Script
# Installs Keycloak Operator (Community) and creates Keycloak instance
# Assumes oc is installed and user is logged in as cluster-admin
# Usage: ./07-install-keycloak.sh

# Exit immediately on error, show error message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RH-SSO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RH-SSO]${NC} $1"
}

error() {
    echo -e "${RED}[RH-SSO] ERROR:${NC} $1" >&2
    echo -e "${RED}[RH-SSO] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Prerequisites validation
log "========================================================="
log "Keycloak Installation (Community Operator)"
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

# Configuration
NAMESPACE="keycloak-operator"
KEYCLOAK_CR_NAME="keycloak"
OPERATOR_PACKAGE="keycloak-operator"
OPERATOR_GROUP_NAME="keycloak-operator-group"
SUBSCRIPTION_NAME="keycloak-operator"
CHANNEL="fast"
OPERATOR_SOURCE="community-operators"

# Ensure namespace exists
log "Ensuring namespace '$NAMESPACE' exists..."
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    log "Creating namespace '$NAMESPACE'..."
    oc create namespace "$NAMESPACE" || error "Failed to create namespace"
fi
log "✓ Namespace '$NAMESPACE' exists"

# Check if Keycloak operator is already installed
log ""
log "Checking Keycloak operator status..."

EXISTING_SUBSCRIPTION=false

if oc get subscription.operators.coreos.com "$SUBSCRIPTION_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    EXISTING_SUBSCRIPTION=true
    CURRENT_CSV=$(oc get subscription.operators.coreos.com "$SUBSCRIPTION_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    EXISTING_CHANNEL=$(oc get subscription.operators.coreos.com "$SUBSCRIPTION_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
    
    if [ -n "$CURRENT_CSV" ] && [ "$CURRENT_CSV" != "null" ]; then
        if oc get csv "$CURRENT_CSV" -n "$NAMESPACE" >/dev/null 2>&1; then
            CSV_PHASE=$(oc get csv "$CURRENT_CSV" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "✓ Keycloak operator is already installed and running"
                log "  Installed CSV: $CURRENT_CSV"
                log "  Current channel: ${EXISTING_CHANNEL:-unknown}"
                log "  Status: $CSV_PHASE"
            else
                log "Keycloak operator subscription exists but CSV is in phase: $CSV_PHASE"
            fi
        else
            log "Keycloak operator subscription exists but CSV not found"
        fi
    else
        log "Keycloak operator subscription exists but CSV not yet determined"
    fi
else
    log "Keycloak operator not found, proceeding with installation..."
fi

# Create or update OperatorGroup
log ""
log "Ensuring OperatorGroup exists..."

EXISTING_OG=$(oc get operatorgroup "$OPERATOR_GROUP_NAME" -n "$NAMESPACE" 2>/dev/null || echo "")

if [ -n "$EXISTING_OG" ]; then
    log "✓ OperatorGroup already exists: $OPERATOR_GROUP_NAME"
else
    log "Creating OperatorGroup..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: $OPERATOR_GROUP_NAME
  namespace: $NAMESPACE
spec:
  targetNamespaces:
  - $NAMESPACE
EOF
    log "✓ OperatorGroup created"
fi

# Create or update Subscription
log ""
log "Creating/updating Subscription..."
log "  Channel: $CHANNEL"
log "  Source: $OPERATOR_SOURCE"
log "  SourceNamespace: openshift-marketplace"

if [ "$EXISTING_SUBSCRIPTION" = true ]; then
    # Update existing subscription if channel changed
    if [ -n "$EXISTING_CHANNEL" ] && [ "$EXISTING_CHANNEL" != "$CHANNEL" ]; then
        log "Updating subscription channel from '$EXISTING_CHANNEL' to '$CHANNEL'..."
        oc patch subscription "$SUBSCRIPTION_NAME" -n "$NAMESPACE" --type merge -p "{\"spec\":{\"channel\":\"$CHANNEL\"}}" || error "Failed to update subscription channel"
    else
        log "✓ Subscription already exists with channel: $CHANNEL"
    fi
else
    log "Creating Subscription..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $SUBSCRIPTION_NAME
  namespace: $NAMESPACE
spec:
  channel: $CHANNEL
  name: $OPERATOR_PACKAGE
  source: $OPERATOR_SOURCE
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
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
    CSV_NAME=$(oc get csv -n "$NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Keycloak Operator")].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n "$NAMESPACE" -o name 2>/dev/null | grep -i "keycloak-operator" | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    fi
    
    if [ -n "$CSV_NAME" ]; then
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
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
    error "CSV did not become ready within ${MAX_WAIT} seconds. Check operator status: oc get csv -n $NAMESPACE"
fi

# Wait for Keycloak CRD to be available
log ""
log "Waiting for Keycloak CRD to be available..."
MAX_WAIT=120
WAIT_COUNT=0
CRD_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if oc get crd keycloaks.k8s.keycloak.org 2>/dev/null; then
        CRD_READY=true
        log "✓ Keycloak CRD is available"
        break
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$CRD_READY" = false ]; then
    error "Keycloak CRD not available after ${MAX_WAIT}s"
fi

# Check if Keycloak CR already exists
log ""
log "Checking for existing Keycloak CR..."

if oc get keycloak "$KEYCLOAK_CR_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "✓ Keycloak CR '$KEYCLOAK_CR_NAME' already exists"
    
    # Check status
    KEYCLOAK_STATUS=$(oc get keycloak "$KEYCLOAK_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$KEYCLOAK_STATUS" = "reconciled" ]; then
        log "✓ Keycloak instance is ready"
        
        # Check for route
        KEYCLOAK_ROUTE=$(oc get route keycloak -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
        if [ -n "$KEYCLOAK_ROUTE" ]; then
            log ""
            log "========================================================="
            log "Red Hat SSO (Keycloak) Installation Completed!"
            log "========================================================="
            log "Namespace: $NAMESPACE"
            log "Keycloak CR: $KEYCLOAK_CR_NAME"
            log "Status: Ready"
            log "Keycloak URL: https://$KEYCLOAK_ROUTE"
            log "========================================================="
            exit 0
        fi
    else
        log "Keycloak exists but status is: ${KEYCLOAK_STATUS:-Unknown}"
        log "Waiting for it to become ready..."
    fi
else
    log "Creating Keycloak CR..."
    
    # Create Keycloak CR - operator will automatically create route
    cat <<EOF | oc apply -f -
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: $KEYCLOAK_CR_NAME
  namespace: $NAMESPACE
  labels:
    app: sso
spec:
  instances: 1
EOF
    log "✓ Keycloak CR created"
fi

# Wait for Keycloak to be ready
log ""
log "Waiting for Keycloak instance to become ready..."
MAX_WAIT=900
WAIT_COUNT=0
KEYCLOAK_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    KEYCLOAK_STATUS=$(oc get keycloak "$KEYCLOAK_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    
    if [ "$KEYCLOAK_STATUS" = "reconciled" ]; then
        KEYCLOAK_READY=true
        log "✓ Keycloak instance is ready"
        break
    fi
    
    if [ $((WAIT_COUNT % 60)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting... (${WAIT_COUNT}s/${MAX_WAIT}s)"
        log "  Current status: ${KEYCLOAK_STATUS:-Unknown}"
    fi
    
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 10))
done

if [ "$KEYCLOAK_READY" = false ]; then
    warning "Keycloak did not become ready within ${MAX_WAIT} seconds"
    log "Current status:"
    oc get keycloak "$KEYCLOAK_CR_NAME" -n "$NAMESPACE" -o yaml
    warning "Keycloak may still be installing. Check operator logs for details."
fi

# Wait for route to be created
log ""
log "Waiting for Keycloak route to be created..."
MAX_WAIT=120
WAIT_COUNT=0
ROUTE_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    KEYCLOAK_ROUTE=$(oc get route keycloak -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -n "$KEYCLOAK_ROUTE" ]; then
        ROUTE_READY=true
        log "✓ Keycloak route is ready: $KEYCLOAK_ROUTE"
        break
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$ROUTE_READY" = false ]; then
    warning "Keycloak route not found after ${MAX_WAIT} seconds"
fi

# Create openshift realm if it doesn't exist
log ""
log "Checking for 'openshift' realm..."

# Get admin credentials
ADMIN_SECRET="credential-${KEYCLOAK_CR_NAME}"
if oc get secret "$ADMIN_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
    ADMIN_USER=$(oc get secret "$ADMIN_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    ADMIN_PASS=$(oc get secret "$ADMIN_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ] && [ -n "$KEYCLOAK_ROUTE" ]; then
        log "✓ Retrieved admin credentials"
        
        # Try to get admin token
        TOKEN_RESPONSE=$(curl -s -X POST "https://${KEYCLOAK_ROUTE}/auth/realms/master/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=${ADMIN_USER}" \
            -d "password=${ADMIN_PASS}" \
            -d "grant_type=password" \
            -d "client_id=admin-cli" 2>/dev/null || echo "")
        
        ADMIN_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4 || echo "")
        
        if [ -n "$ADMIN_TOKEN" ]; then
            log "✓ Authenticated to Keycloak admin console"
            
            # Check if openshift realm exists
            REALM_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "Authorization: Bearer ${ADMIN_TOKEN}" \
                "https://${KEYCLOAK_ROUTE}/auth/admin/realms/openshift" 2>/dev/null || echo "000")
            
            if [ "$REALM_CHECK" = "200" ]; then
                log "✓ Realm 'openshift' already exists"
            else
                log "Creating realm 'openshift'..."
                
                REALM_CONFIG=$(cat <<EOF
{
  "realm": "openshift",
  "enabled": true,
  "displayName": "OpenShift Realm"
}
EOF
)
                
                REALM_CREATE_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
                    -X POST \
                    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
                    -H "Content-Type: application/json" \
                    -d "${REALM_CONFIG}" \
                    "https://${KEYCLOAK_ROUTE}/auth/admin/realms" 2>/dev/null || echo "000")
                
                if [ "$REALM_CREATE_RESPONSE" = "201" ]; then
                    log "✓ Realm 'openshift' created successfully"
                else
                    warning "Failed to create realm 'openshift' (HTTP $REALM_CREATE_RESPONSE)"
                    warning "You may need to create it manually in the Keycloak admin console"
                fi
            fi
        else
            warning "Could not authenticate to Keycloak admin console"
            warning "You may need to create the 'openshift' realm manually"
        fi
    else
        warning "Could not retrieve admin credentials"
    fi
else
    warning "Admin secret '$ADMIN_SECRET' not found"
    warning "You may need to create the 'openshift' realm manually"
fi

# Final summary
log ""
log "========================================================="
log "Red Hat SSO (Keycloak) Installation Completed!"
log "========================================================="
log "Namespace: $NAMESPACE"
log "Keycloak CR: $KEYCLOAK_CR_NAME"
log "Status: ${KEYCLOAK_STATUS:-Installing}"

if [ -n "$KEYCLOAK_ROUTE" ]; then
    log "Keycloak URL: https://$KEYCLOAK_ROUTE"
    log "Admin Console: https://$KEYCLOAK_ROUTE/auth/admin"
fi

if [ -n "$ADMIN_USER" ]; then
    log "Admin Username: $ADMIN_USER"
fi

log ""
log "Next steps:"
log "1. Access the Keycloak admin console to configure realms and clients"
log "2. Run the RHTAS installation script to create OAuth clients"
log "========================================================="
log ""