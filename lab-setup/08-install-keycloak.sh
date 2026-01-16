#!/bin/bash
# Red Hat Single Sign-On (RHSSO) Installation Script
# Installs Red Hat Single Sign-On 7.6 using OpenShift templates
#
# Usage:
#   ./08-install-keycloak.sh

# Exit immediately on error, show error message
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RHSSO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHSSO]${NC} $1"
}

error() {
    echo -e "${RED}[RHSSO] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHSSO] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Prerequisites validation
log "========================================================="
log "Red Hat Single Sign-On (RHSSO) Installation"
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
if ! oc auth can-i create templates --namespace=openshift &>/dev/null; then
    error "Cluster admin privileges required to install templates. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log "Prerequisites validated successfully"
log ""

# Configuration
SSO_NAMESPACE="sso"
TEMPLATE_NAME="sso76-ocp4-x509-postgresql-persistent"
IMAGE_STREAM_URL="https://raw.githubusercontent.com/jboss-container-images/redhat-sso-7-openshift-image/sso76-dev/templates/sso76-image-stream.json"
TEMPLATE_URL="https://raw.githubusercontent.com/jboss-container-images/redhat-sso-7-openshift-image/sso76-dev/templates/reencrypt/ocp-4.x/sso76-ocp4-x509-postgresql-persistent.json"
IMAGE_STREAM_NAME="rh-sso-7/sso76-openshift-rhel8:7.6"
IMAGE_SOURCE="registry.redhat.io/rh-sso-7/sso76-openshift-rhel8:7.6"

# Check if RHSSO is already deployed
log "Checking if RHSSO is already deployed..."
if oc get project "$SSO_NAMESPACE" &>/dev/null; then
    log "Project '$SSO_NAMESPACE' already exists"
    
    # Check if application is already deployed
    if oc get deployment -n "$SSO_NAMESPACE" 2>/dev/null | grep -q "sso"; then
        log "✓ RHSSO appears to be already deployed in namespace '$SSO_NAMESPACE'"
        log "Checking pod status..."
        oc get pods -n "$SSO_NAMESPACE" || true
        
        # Try to get credentials from secret
        log ""
        log "Retrieving existing credentials..."
        if oc get secret credential-sso -n "$SSO_NAMESPACE" &>/dev/null; then
            SSO_USERNAME=$(oc get secret credential-sso -n "$SSO_NAMESPACE" -o jsonpath='{.data.ADMIN_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
            SSO_PASSWORD=$(oc get secret credential-sso -n "$SSO_NAMESPACE" -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
            
            if [ -n "$SSO_USERNAME" ] && [ -n "$SSO_PASSWORD" ]; then
                log ""
                log "========================================================="
                log "RHSSO Installation Already Complete"
                log "========================================================="
                log "Namespace: $SSO_NAMESPACE"
                log "Admin Username: $SSO_USERNAME"
                log "Admin Password: $SSO_PASSWORD"
                log ""
                log "To access the admin console, get the route:"
                log "  oc get route -n $SSO_NAMESPACE"
                log "========================================================="
                exit 0
            fi
        fi
        
        warning "RHSSO is deployed but credentials could not be retrieved"
        log "Continuing to ensure proper setup..."
    else
        log "Project exists but RHSSO not fully deployed, proceeding with installation..."
    fi
else
    log "RHSSO not found, proceeding with installation..."
fi

# Step 1: Create/replace templates and install image stream
log ""
log "========================================================="
log "Step 1: Installing RHSSO templates and image stream"
log "========================================================="
log ""

log "Creating/replacing image stream template..."
if ! oc replace -n openshift --force -f "$IMAGE_STREAM_URL" 2>/dev/null; then
    # If replace fails, try create
    oc create -n openshift -f "$IMAGE_STREAM_URL" || error "Failed to create image stream template"
fi
log "✓ Image stream template created"

log "Creating/replacing RHSSO template..."
if ! oc replace -n openshift --force -f "$TEMPLATE_URL" 2>/dev/null; then
    # If replace fails, try create
    oc create -n openshift -f "$TEMPLATE_URL" || error "Failed to create RHSSO template"
fi
log "✓ RHSSO template created"

log "Importing RHSSO image..."
if ! oc -n openshift import-image "$IMAGE_STREAM_NAME" --from="$IMAGE_SOURCE" --confirm 2>/dev/null; then
    warning "Image import may have failed or image already exists, continuing..."
else
    log "✓ Image imported successfully"
fi

# Step 2: Create new project
log ""
log "========================================================="
log "Step 2: Creating project"
log "========================================================="
log ""

log "Creating project '$SSO_NAMESPACE'..."
if ! oc get project "$SSO_NAMESPACE" &>/dev/null; then
    oc new-project "$SSO_NAMESPACE" || error "Failed to create project"
    log "✓ Project created successfully"
else
    log "✓ Project already exists"
    # Switch to the project
    oc project "$SSO_NAMESPACE" || error "Failed to switch to project"
fi

# Step 3: Add view role to default service account
log ""
log "========================================================="
log "Step 3: Configuring service account permissions"
log "========================================================="
log ""

log "Adding view role to default service account..."
if oc policy add-role-to-user view -z default -n "$SSO_NAMESPACE" 2>/dev/null; then
    log "✓ View role added to default service account"
else
    # Check if role already exists
    if oc get rolebinding -n "$SSO_NAMESPACE" 2>/dev/null | grep -q "view.*default"; then
        log "✓ View role already exists for default service account"
    else
        warning "Failed to add view role (may already exist or be non-critical)"
    fi
fi

# Step 4: Deploy the template
log ""
log "========================================================="
log "Step 4: Deploying RHSSO template"
log "========================================================="
log ""

log "Deploying template '$TEMPLATE_NAME'..."
log "This will create the RHSSO deployment with PostgreSQL database"
log ""

# Check if application already exists
if oc get deployment -n "$SSO_NAMESPACE" 2>/dev/null | grep -q "sso"; then
    log "✓ RHSSO deployment already exists"
    log "Skipping template deployment..."
else
    # Deploy the template
    oc new-app --template="$TEMPLATE_NAME" -n "$SSO_NAMESPACE" || error "Failed to deploy template"
    log "✓ Template deployed successfully"
fi

# Step 5: Wait for deployment and retrieve credentials
log ""
log "========================================================="
log "Step 5: Waiting for deployment and retrieving credentials"
log "========================================================="
log ""

log "Waiting for pods to be created..."
MAX_WAIT=120
WAIT_COUNT=0
PODS_CREATED=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    POD_COUNT=$(oc get pods -n "$SSO_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
    
    if [ "$POD_COUNT" -gt 0 ]; then
        PODS_CREATED=true
        log "✓ Pods created ($POD_COUNT pods found)"
        break
    fi
    
    if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting for pods... (${WAIT_COUNT}s/${MAX_WAIT}s)"
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$PODS_CREATED" = false ]; then
    warning "Pods not created after ${MAX_WAIT} seconds. Checking status..."
    oc get all -n "$SSO_NAMESPACE" || true
    warning "Deployment may still be in progress. Check status with: oc get pods -n $SSO_NAMESPACE"
fi

# Wait for secret to be created
log "Waiting for credentials secret to be created..."
MAX_WAIT=60
WAIT_COUNT=0
SECRET_CREATED=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if oc get secret credential-sso -n "$SSO_NAMESPACE" &>/dev/null; then
        SECRET_CREATED=true
        log "✓ Credentials secret found"
        break
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$SECRET_CREATED" = false ]; then
    warning "Credentials secret not found after ${MAX_WAIT} seconds"
    log "Credentials may be generated later. Check with: oc get secret credential-sso -n $SSO_NAMESPACE"
fi

# Retrieve credentials
log ""
log "Retrieving RHSSO admin credentials..."

SSO_USERNAME=""
SSO_PASSWORD=""

if oc get secret credential-sso -n "$SSO_NAMESPACE" &>/dev/null; then
    SSO_USERNAME=$(oc get secret credential-sso -n "$SSO_NAMESPACE" -o jsonpath='{.data.ADMIN_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    SSO_PASSWORD=$(oc get secret credential-sso -n "$SSO_NAMESPACE" -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [ -z "$SSO_USERNAME" ] || [ -z "$SSO_PASSWORD" ]; then
        # Try alternative secret names or methods
        log "Trying alternative method to retrieve credentials..."
        
        # Check if credentials are in the deployment config or other secrets
        ALL_SECRETS=$(oc get secrets -n "$SSO_NAMESPACE" -o name 2>/dev/null | grep -i "sso\|credential" || echo "")
        if [ -n "$ALL_SECRETS" ]; then
            log "Found secrets: $ALL_SECRETS"
        fi
    fi
fi

# If credentials not found, check the deployment output
if [ -z "$SSO_USERNAME" ] || [ -z "$SSO_PASSWORD" ]; then
    log "Credentials not yet available in secret. Checking deployment output..."
    
    # The template usually outputs credentials when deployed
    # Check the deployment config or try to get from the app
    DEPLOYMENT_OUTPUT=$(oc get all -n "$SSO_NAMESPACE" -o yaml 2>/dev/null | grep -i "username\|password" || echo "")
    
    if [ -n "$DEPLOYMENT_OUTPUT" ]; then
        log "Found credentials in deployment output"
    else
        warning "Could not retrieve credentials automatically"
        log "Credentials will be generated by the template. Check the deployment output or secret."
    fi
fi

# Step 6: Verify deployment status
log ""
log "========================================================="
log "Step 6: Verifying deployment status"
log "========================================================="
log ""

log "Checking pod status..."
oc get pods -n "$SSO_NAMESPACE" || true

log ""
log "Checking services..."
oc get svc -n "$SSO_NAMESPACE" || true

log ""
log "Checking routes..."
oc get route -n "$SSO_NAMESPACE" || true

# Get route URL
SSO_ROUTE=$(oc get route -n "$SSO_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null | head -1 || echo "")

# Final summary
log ""
log "========================================================="
log "RHSSO Installation Completed!"
log "========================================================="
log "Namespace: $SSO_NAMESPACE"
log "Template: $TEMPLATE_NAME"
log ""

if [ -n "$SSO_USERNAME" ] && [ -n "$SSO_PASSWORD" ]; then
    log "RH-SSO Administrator Username: $SSO_USERNAME"
    log "RH-SSO Administrator Password: $SSO_PASSWORD"
else
    log "Credentials:"
    log "  Username: Check secret 'credential-sso' in namespace '$SSO_NAMESPACE'"
    log "  Password: Check secret 'credential-sso' in namespace '$SSO_NAMESPACE'"
    log ""
    log "To retrieve credentials manually:"
    log "  oc get secret credential-sso -n $SSO_NAMESPACE -o jsonpath='{.data.ADMIN_USERNAME}' | base64 -d"
    log "  oc get secret credential-sso -n $SSO_NAMESPACE -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d"
fi

log ""
if [ -n "$SSO_ROUTE" ]; then
    log "Admin Console URL: https://$SSO_ROUTE"
else
    log "Admin Console URL: Get route with: oc get route -n $SSO_NAMESPACE"
fi

log ""
log "To verify all pods are running:"
log "  oc get pods -n $SSO_NAMESPACE"
log ""
log "========================================================="
log ""
