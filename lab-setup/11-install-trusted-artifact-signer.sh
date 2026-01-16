#!/bin/bash

# Script to install Red Hat Trusted Artifact Signer (RHTAS) with Red Hat SSO (Keycloak) as OIDC provider on OpenShift
# Assumes oc is installed and user is logged in as cluster-admin
# Assumes Red Hat SSO (Keycloak) is installed in the rhsso namespace
# Usage: ./08-install-trusted-artifact-signer.sh

# Step 1: Get Red Hat SSO (Keycloak) OIDC Issuer URL
echo "Retrieving Red Hat SSO (Keycloak) OIDC Issuer URL..."

# Check if Keycloak namespace exists
if ! oc get namespace rhsso >/dev/null 2>&1; then
    echo "Error: Namespace 'rhsso' does not exist"
    echo "Please install Red Hat SSO (Keycloak) first by running: ./07-install-keycloak.sh"
    exit 1
fi

# Check if Keycloak CR exists
if ! oc get keycloak keycloak -n rhsso >/dev/null 2>&1; then
    echo "Error: Keycloak custom resource not found in rhsso namespace"
    echo "Please install Red Hat SSO (Keycloak) first by running: ./07-install-keycloak.sh"
    exit 1
fi

KEYCLOAK_ROUTE=$(oc get route keycloak -n rhsso -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$KEYCLOAK_ROUTE" ]; then
    echo "Error: Could not retrieve Keycloak route from rhsso namespace"
    echo "Keycloak may still be installing. Please wait for it to be ready, or run: ./07-install-keycloak.sh"
    exit 1
fi

KEYCLOAK_URL="https://${KEYCLOAK_ROUTE}"
OIDC_ISSUER_URL="${KEYCLOAK_URL}/auth/realms/openshift"
echo "✓ Red Hat SSO (Keycloak) URL: $KEYCLOAK_URL"
echo "✓ OIDC Issuer URL: $OIDC_ISSUER_URL"

# Step 2: Create OAuth Client in Red Hat SSO (Keycloak) for Trusted Artifact Signer
echo "Creating OAuth Client in Red Hat SSO (Keycloak) for Trusted Artifact Signer..."
OIDC_CLIENT_ID="trusted-artifact-signer"
REALM="openshift"

# Function to get Keycloak admin credentials
get_keycloak_admin_creds() {
    # Try to get admin credentials from secret
    ADMIN_USER=$(oc get secret credential-rhsso -n rhsso -o jsonpath='{.data.ADMIN_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    ADMIN_PASS=$(oc get secret credential-rhsso -n rhsso -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    # If not found, try alternative secret names
    if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
        ADMIN_USER=$(oc get secret keycloak-admin-credential -n rhsso -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        ADMIN_PASS=$(oc get secret keycloak-admin-credential -n rhsso -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    fi
    
    # If still not found, try from Keycloak CR
    if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
        ADMIN_USER=$(oc get keycloak keycloak -n rhsso -o jsonpath='{.spec.externalAccess.user}' 2>/dev/null || echo "admin")
        ADMIN_PASS=$(oc get secret credential-rhsso -n rhsso -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    fi
    
    echo "$ADMIN_USER|$ADMIN_PASS"
}

# Get admin token from Keycloak
get_admin_token() {
    local admin_user=$1
    local admin_pass=$2
    local keycloak_url=$3
    
    TOKEN_RESPONSE=$(curl -s -X POST "${keycloak_url}/auth/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${admin_user}" \
        -d "password=${admin_pass}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" 2>/dev/null)
    
    echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4
}

# Check if client already exists
check_client_exists() {
    local admin_token=$1
    local keycloak_url=$2
    local realm=$3
    local client_id=$4
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${admin_token}" \
        "${keycloak_url}/auth/admin/realms/${realm}/clients?clientId=${client_id}" 2>/dev/null)
    
    if [ "$HTTP_CODE" = "200" ]; then
        CLIENT_LIST=$(curl -s \
            -H "Authorization: Bearer ${admin_token}" \
            "${keycloak_url}/auth/admin/realms/${realm}/clients?clientId=${client_id}" 2>/dev/null)
        
        if echo "$CLIENT_LIST" | grep -q "\"clientId\":\"${client_id}\""; then
            return 0
        fi
    fi
    return 1
}

# Create client in Keycloak
create_keycloak_client() {
    local admin_token=$1
    local keycloak_url=$2
    local realm=$3
    local client_id=$4
    
    CLIENT_CONFIG=$(cat <<EOF
{
  "clientId": "${client_id}",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": true,
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": true,
  "redirectUris": [
    "http://localhost/auth/callback",
    "urn:ietf:wg:oauth:2.0:oob"
  ],
  "webOrigins": ["+"],
  "attributes": {
    "access.token.lifespan": "300"
  }
}
EOF
)
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${admin_token}" \
        -H "Content-Type: application/json" \
        -d "${CLIENT_CONFIG}" \
        "${keycloak_url}/auth/admin/realms/${realm}/clients" 2>/dev/null)
    
    if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "409" ]; then
        return 0
    else
        return 1
    fi
}

# Get admin credentials
echo "Retrieving Keycloak admin credentials..."
CREDS=$(get_keycloak_admin_creds)
ADMIN_USER=$(echo "$CREDS" | cut -d'|' -f1)
ADMIN_PASS=$(echo "$CREDS" | cut -d'|' -f2)

if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
    echo "Warning: Could not retrieve Keycloak admin credentials automatically"
    echo "You may need to create the OAuth client manually in the Keycloak admin console"
    echo "Client ID: ${OIDC_CLIENT_ID}"
    echo "Realm: ${REALM}"
    echo "Redirect URIs: http://localhost/auth/callback, urn:ietf:wg:oauth:2.0:oob"
    echo "Public Client: Yes"
else
    echo "✓ Retrieved Keycloak admin credentials"
    
    # Get admin token
    echo "Authenticating to Keycloak..."
    ADMIN_TOKEN=$(get_admin_token "$ADMIN_USER" "$ADMIN_PASS" "$KEYCLOAK_URL")
    
    if [ -z "$ADMIN_TOKEN" ]; then
        echo "Warning: Could not authenticate to Keycloak"
        echo "You may need to create the OAuth client manually in the Keycloak admin console"
    else
        echo "✓ Authenticated to Keycloak"
        
        # Check if client already exists
        if check_client_exists "$ADMIN_TOKEN" "$KEYCLOAK_URL" "$REALM" "$OIDC_CLIENT_ID"; then
            echo "OAuth client '${OIDC_CLIENT_ID}' already exists in Keycloak realm '${REALM}', skipping creation"
        else
            # Create the client
            if create_keycloak_client "$ADMIN_TOKEN" "$KEYCLOAK_URL" "$REALM" "$OIDC_CLIENT_ID"; then
                echo "✓ OAuth client '${OIDC_CLIENT_ID}' created in Keycloak realm '${REALM}'"
            else
                echo "Warning: Failed to create OAuth client in Keycloak"
                echo "You may need to create it manually in the Keycloak admin console"
            fi
        fi
    fi
fi

# Step 3: Install RHTAS Operator
echo "Installing RHTAS Operator..."

# Check if subscription already exists
if oc get subscription trusted-artifact-signer -n openshift-operators 2>/dev/null; then
    echo "RHTAS Operator subscription 'trusted-artifact-signer' already exists, skipping creation"
else
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: trusted-artifact-signer
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhtas-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: rhtas-operator.v1.3.1
EOF
    echo "✓ RHTAS Operator subscription created"
fi

# Wait for RHTAS Operator to be ready
echo "Waiting for RHTAS Operator to be ready..."

# First, wait for CSV to appear
echo "Waiting for CSV to be created..."
CSV_NAME=""
MAX_WAIT_CSV=120
WAIT_COUNT=0

while [ $WAIT_COUNT -lt $MAX_WAIT_CSV ]; do
    # Try multiple methods to find the CSV
    CSV_NAME=$(oc get csv -n openshift-operators -o jsonpath='{.items[?(@.spec.displayName=="Trusted Artifact Signer Operator")].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n openshift-operators -o name 2>/dev/null | grep -i "trusted-artifact-signer\|rhtas" | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    fi
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n openshift-operators -l operators.coreos.com/trusted-artifact-signer.openshift-operators -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    if [ -n "$CSV_NAME" ]; then
        echo "✓ Found CSV: $CSV_NAME"
        break
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for CSV to appear... (${WAIT_COUNT}s/${MAX_WAIT_CSV}s)"
        echo "    Checking available CSVs..."
        oc get csv -n openshift-operators -o name 2>/dev/null | head -3 || echo "    No CSVs found yet"
    fi
done
