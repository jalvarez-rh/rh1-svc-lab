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
    echo "Please install Red Hat SSO (Keycloak) first by running: ./01-keycloak.sh"
    exit 1
fi

# Determine the correct CRD name (try both singular and plural)
KEYCLOAK_CRD="keycloaks"
if oc get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1 || oc get crd keycloaks.keycloak.org >/dev/null 2>&1; then
    KEYCLOAK_CRD="keycloaks"
elif oc get crd keycloak.k8s.keycloak.org >/dev/null 2>&1 || oc get crd keycloak.keycloak.org >/dev/null 2>&1; then
    KEYCLOAK_CRD="keycloak"
else
    # Try to determine by attempting to list resources
    if oc get keycloaks -n rhsso >/dev/null 2>&1; then
        KEYCLOAK_CRD="keycloaks"
    elif oc get keycloak -n rhsso >/dev/null 2>&1; then
        KEYCLOAK_CRD="keycloak"
    else
        KEYCLOAK_CRD="keycloak"
    fi
fi

KEYCLOAK_CR_NAME="rhsso-instance"

# Check if Keycloak CR exists, or if resources are running
KEYCLOAK_CR_EXISTS=false
if oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n rhsso >/dev/null 2>&1; then
    KEYCLOAK_CR_EXISTS=true
elif oc get $KEYCLOAK_CRD keycloak -n rhsso >/dev/null 2>&1; then
    KEYCLOAK_CR_NAME="keycloak"
    KEYCLOAK_CR_EXISTS=true
else
    # Check if resources are running even without CR
    KEYCLOAK_STS_READY=$(oc get statefulset keycloak -n rhsso -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "")
    KEYCLOAK_POD_RUNNING=$(oc get pod -n rhsso -l app=keycloak --field-selector=status.phase=Running -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    
    if [ "$KEYCLOAK_STS_READY" = "1/1" ] && [ "$KEYCLOAK_POD_RUNNING" = "Running" ]; then
        echo "✓ Keycloak resources are running (CR not found, but installation appears successful)"
        KEYCLOAK_CR_EXISTS=false
    else
        echo "Error: Keycloak custom resource not found in rhsso namespace and resources are not running"
        echo "Please install Red Hat SSO (Keycloak) first by running: ./01-keycloak.sh"
        exit 1
    fi
fi

KEYCLOAK_ROUTE=$(oc get route keycloak -n rhsso -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$KEYCLOAK_ROUTE" ]; then
    echo "Error: Could not retrieve Keycloak route from rhsso namespace"
    echo "Keycloak may still be installing. Please wait for it to be ready, or run: ./01-keycloak.sh"
    exit 1
fi

KEYCLOAK_URL="https://${KEYCLOAK_ROUTE}"
OIDC_ISSUER_URL="${KEYCLOAK_URL}/auth/realms/openshift"
echo "✓ Red Hat SSO (Keycloak) URL: $KEYCLOAK_URL"
echo "✓ OIDC Issuer URL: $OIDC_ISSUER_URL"

# Step 2: Wait for Keycloak instance to be ready before creating realms/clients
echo "Waiting for Keycloak instance to be ready..."
KEYCLOAK_CR_NAME="rhsso-instance"
KEYCLOAK_CRD="keycloaks"
if ! oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n rhsso >/dev/null 2>&1; then
    KEYCLOAK_CRD="keycloak"
fi

MAX_WAIT_KEYCLOAK=300
WAIT_COUNT=0
KEYCLOAK_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT_KEYCLOAK ]; do
    KEYCLOAK_READY_STATUS=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n rhsso -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    KEYCLOAK_PHASE=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    
    if [ "$KEYCLOAK_READY_STATUS" = "true" ] || [ "$KEYCLOAK_PHASE" = "reconciled" ]; then
        KEYCLOAK_READY=true
        echo "✓ Keycloak instance is ready"
        break
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for Keycloak instance... (${WAIT_COUNT}s/${MAX_WAIT_KEYCLOAK}s) - Phase: ${KEYCLOAK_PHASE:-unknown}, Ready: ${KEYCLOAK_READY_STATUS:-false}"
    fi
done

if [ "$KEYCLOAK_READY" = false ]; then
    echo "Warning: Keycloak instance did not become ready within ${MAX_WAIT_KEYCLOAK} seconds, but continuing..."
fi

# Step 3: Ensure OpenShift realm exists (using KeycloakRealm CR)
echo ""
echo "Ensuring OpenShift realm exists..."
REALM="openshift"
REALM_CR_NAME="openshift"

# Check if KeycloakRealm CR exists
if oc get keycloakrealm $REALM_CR_NAME -n rhsso >/dev/null 2>&1; then
    echo "✓ KeycloakRealm CR '${REALM_CR_NAME}' already exists"
    
    # Wait for realm to be ready/reconciled
    echo "Waiting for realm to be reconciled..."
    MAX_WAIT_REALM=300
    WAIT_COUNT=0
    REALM_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_REALM ]; do
        REALM_STATUS=$(oc get keycloakrealm $REALM_CR_NAME -n rhsso -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        REALM_PHASE=$(oc get keycloakrealm $REALM_CR_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$REALM_STATUS" = "true" ] || [ "$REALM_PHASE" = "reconciled" ]; then
            REALM_READY=true
            echo "✓ Realm is reconciled"
            break
        fi
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for realm... (${WAIT_COUNT}s/${MAX_WAIT_REALM}s) - Phase: ${REALM_PHASE:-unknown}, Ready: ${REALM_STATUS:-false}"
        fi
    done
    
    if [ "$REALM_READY" = false ]; then
        echo "Warning: Realm did not become reconciled within ${MAX_WAIT_REALM} seconds, but continuing..."
    fi
else
    echo "Creating KeycloakRealm CR '${REALM_CR_NAME}'..."
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakRealm
metadata:
  name: ${REALM_CR_NAME}
  namespace: rhsso
  labels:
    app: openshift
spec:
  instanceSelector:
    matchLabels:
      app: sso
  realm:
    displayName: Openshift Authentication Realm
    enabled: true
    id: ${REALM}
    realm: ${REALM}
EOF
    then
        echo "Error: Failed to create KeycloakRealm CR"
        exit 1
    fi
    
    echo "✓ KeycloakRealm CR created successfully"
    
    # Wait for realm to be ready/reconciled
    echo "Waiting for realm to be reconciled..."
    MAX_WAIT_REALM=300
    WAIT_COUNT=0
    REALM_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_REALM ]; do
        REALM_STATUS=$(oc get keycloakrealm $REALM_CR_NAME -n rhsso -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        REALM_PHASE=$(oc get keycloakrealm $REALM_CR_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$REALM_STATUS" = "true" ] || [ "$REALM_PHASE" = "reconciled" ]; then
            REALM_READY=true
            echo "✓ Realm is reconciled"
            break
        fi
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for realm... (${WAIT_COUNT}s/${MAX_WAIT_REALM}s) - Phase: ${REALM_PHASE:-unknown}, Ready: ${REALM_STATUS:-false}"
        fi
    done
    
    if [ "$REALM_READY" = false ]; then
        echo "Warning: Realm did not become reconciled within ${MAX_WAIT_REALM} seconds, but continuing..."
    fi
fi

# Step 4: Create Keycloak User for authentication
echo ""
echo "Creating Keycloak User for authentication..."
KEYCLOAK_USER_NAME="admin"
KEYCLOAK_USER_USERNAME="admin"
KEYCLOAK_USER_EMAIL="admin@demo.redhat.com"
KEYCLOAK_USER_PASSWORD="116608"  # Default password, can be changed

# Check if KeycloakUser CR already exists
if oc get keycloakuser $KEYCLOAK_USER_NAME -n rhsso >/dev/null 2>&1; then
    echo "✓ KeycloakUser CR '${KEYCLOAK_USER_NAME}' already exists"
    
    # Wait for user to be ready
    echo "Waiting for user to be ready..."
    MAX_WAIT_USER=120
    WAIT_COUNT=0
    USER_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_USER ]; do
        USER_PHASE=$(oc get keycloakuser $KEYCLOAK_USER_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$USER_PHASE" = "reconciled" ]; then
            USER_READY=true
            echo "✓ User is ready"
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for user to be ready... (${WAIT_COUNT}s/${MAX_WAIT_USER}s) - Phase: ${USER_PHASE:-unknown}"
        fi
    done
    
    if [ "$USER_READY" = false ]; then
        echo "Warning: User did not become ready within ${MAX_WAIT_USER} seconds, but continuing..."
    fi
else
    echo "Creating KeycloakUser CR '${KEYCLOAK_USER_NAME}'..."
    
    # Encode password to base64
    KEYCLOAK_USER_PASSWORD_B64=$(echo -n "$KEYCLOAK_USER_PASSWORD" | base64)
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakUser
metadata:
  name: ${KEYCLOAK_USER_NAME}
  namespace: rhsso
  labels:
    app: openshift
spec:
  realmSelector:
    matchLabels:
      app: openshift
  user:
    username: ${KEYCLOAK_USER_USERNAME}
    email: ${KEYCLOAK_USER_EMAIL}
    emailVerified: true
    enabled: true
    credentials:
      - type: password
        value: ${KEYCLOAK_USER_PASSWORD_B64}
EOF
    then
        echo "Error: Failed to create KeycloakUser CR"
        exit 1
    fi
    
    echo "✓ KeycloakUser CR created successfully"
    
    # Wait for user to be ready
    echo "Waiting for user to be ready..."
    MAX_WAIT_USER=120
    WAIT_COUNT=0
    USER_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_USER ]; do
        USER_PHASE=$(oc get keycloakuser $KEYCLOAK_USER_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$USER_PHASE" = "reconciled" ]; then
            USER_READY=true
            echo "✓ User is ready"
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for user to be ready... (${WAIT_COUNT}s/${MAX_WAIT_USER}s) - Phase: ${USER_PHASE:-unknown}"
        fi
    done
    
    if [ "$USER_READY" = false ]; then
        echo "Warning: User did not become ready within ${MAX_WAIT_USER} seconds, but continuing..."
    fi
fi

# Step 3b: Create jdoe Keycloak User for signing
echo ""
echo "Creating jdoe Keycloak User for signing..."
KEYCLOAK_USER_NAME_JDOE="jdoe"
KEYCLOAK_USER_USERNAME_JDOE="jdoe"
KEYCLOAK_USER_EMAIL_JDOE="jdoe@redhat.com"
KEYCLOAK_USER_PASSWORD_JDOE="secure"

# Check if KeycloakUser CR already exists
if oc get keycloakuser $KEYCLOAK_USER_NAME_JDOE -n rhsso >/dev/null 2>&1; then
    echo "✓ KeycloakUser CR '${KEYCLOAK_USER_NAME_JDOE}' already exists"
    
    # Wait for user to be ready
    echo "Waiting for user to be ready..."
    MAX_WAIT_USER=120
    WAIT_COUNT=0
    USER_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_USER ]; do
        USER_PHASE=$(oc get keycloakuser $KEYCLOAK_USER_NAME_JDOE -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$USER_PHASE" = "reconciled" ]; then
            USER_READY=true
            echo "✓ User is ready"
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for user to be ready... (${WAIT_COUNT}s/${MAX_WAIT_USER}s) - Phase: ${USER_PHASE:-unknown}"
        fi
    done
    
    if [ "$USER_READY" = false ]; then
        echo "Warning: User did not become ready within ${MAX_WAIT_USER} seconds, but continuing..."
    fi
else
    echo "Creating KeycloakUser CR '${KEYCLOAK_USER_NAME_JDOE}'..."
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakUser
metadata:
  name: ${KEYCLOAK_USER_NAME_JDOE}
  namespace: rhsso
  labels:
    app: trusted-artifact-signer
spec:
  realmSelector:
    matchLabels:
      app: openshift
  user:
    username: ${KEYCLOAK_USER_USERNAME_JDOE}
    email: ${KEYCLOAK_USER_EMAIL_JDOE}
    emailVerified: true
    enabled: true
    firstName: Jane
    lastName: Doe
    credentials:
      - type: password
        value: ${KEYCLOAK_USER_PASSWORD_JDOE}
EOF
    then
        echo "Error: Failed to create KeycloakUser CR for jdoe"
        exit 1
    fi
    
    echo "✓ KeycloakUser CR created successfully"
    
    # Wait for user to be ready
    echo "Waiting for user to be ready..."
    MAX_WAIT_USER=120
    WAIT_COUNT=0
    USER_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_USER ]; do
        USER_PHASE=$(oc get keycloakuser $KEYCLOAK_USER_NAME_JDOE -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$USER_PHASE" = "reconciled" ]; then
            USER_READY=true
            echo "✓ User is ready"
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for user to be ready... (${WAIT_COUNT}s/${MAX_WAIT_USER}s) - Phase: ${USER_PHASE:-unknown}"
        fi
    done
    
    if [ "$USER_READY" = false ]; then
        echo "Warning: User did not become ready within ${MAX_WAIT_USER} seconds, but continuing..."
    fi
fi

# Step 4: Create OAuth Client in Red Hat SSO (Keycloak) for Trusted Artifact Signer
echo ""
echo "Creating OAuth Client in Red Hat SSO (Keycloak) for Trusted Artifact Signer..."
OIDC_CLIENT_ID="trusted-artifact-signer"
CLIENT_CR_NAME="trusted-artifact-signer"

# Check if KeycloakClient CR already exists
if oc get keycloakclient $CLIENT_CR_NAME -n rhsso >/dev/null 2>&1; then
    echo "✓ KeycloakClient CR '${CLIENT_CR_NAME}' already exists"
    
    # Wait for client to be ready/reconciled
    echo "Waiting for client to be reconciled..."
    MAX_WAIT_CLIENT=300
    WAIT_COUNT=0
    CLIENT_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_CLIENT ]; do
        CLIENT_STATUS=$(oc get keycloakclient $CLIENT_CR_NAME -n rhsso -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        CLIENT_PHASE=$(oc get keycloakclient $CLIENT_CR_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$CLIENT_STATUS" = "true" ] || [ "$CLIENT_PHASE" = "reconciled" ]; then
            CLIENT_READY=true
            echo "✓ Client is reconciled"
            break
        fi
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for client... (${WAIT_COUNT}s/${MAX_WAIT_CLIENT}s) - Phase: ${CLIENT_PHASE:-unknown}, Ready: ${CLIENT_STATUS:-false}"
        fi
    done
    
    if [ "$CLIENT_READY" = false ]; then
        echo "Warning: Client did not become reconciled within ${MAX_WAIT_CLIENT} seconds, but continuing..."
    fi
else
    echo "Creating KeycloakClient CR '${CLIENT_CR_NAME}'..."
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakClient
metadata:
  name: ${CLIENT_CR_NAME}
  namespace: rhsso
  labels:
    app: keycloak
spec:
  realmSelector:
    matchLabels:
      app: openshift
  client:
    clientId: ${OIDC_CLIENT_ID}
    enabled: true
    protocol: openid-connect
    publicClient: true
    standardFlowEnabled: true
    directAccessGrantsEnabled: true
    redirectUris:
      - "http://localhost/auth/callback"
      - "urn:ietf:wg:oauth:2.0:oob"
    webOrigins:
      - "+"
    defaultScopes:
      - "openid"
      - "email"
    attributes:
      access.token.lifespan: "300"
EOF
    then
        echo "Error: Failed to create KeycloakClient CR"
        exit 1
    fi
    
    echo "✓ KeycloakClient CR created successfully"
    
    # Wait for client to be ready/reconciled
    echo "Waiting for client to be reconciled..."
    MAX_WAIT_CLIENT=300
    WAIT_COUNT=0
    CLIENT_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_CLIENT ]; do
        CLIENT_STATUS=$(oc get keycloakclient $CLIENT_CR_NAME -n rhsso -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        CLIENT_PHASE=$(oc get keycloakclient $CLIENT_CR_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$CLIENT_STATUS" = "true" ] || [ "$CLIENT_PHASE" = "reconciled" ]; then
            CLIENT_READY=true
            echo "✓ Client is reconciled"
            break
        fi
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for client... (${WAIT_COUNT}s/${MAX_WAIT_CLIENT}s) - Phase: ${CLIENT_PHASE:-unknown}, Ready: ${CLIENT_STATUS:-false}"
        fi
    done
    
    if [ "$CLIENT_READY" = false ]; then
        echo "Warning: Client did not become reconciled within ${MAX_WAIT_CLIENT} seconds, but continuing..."
    fi
fi

# Check if client secret was created
CLIENT_SECRET_NAME="keycloak-client-secret-${CLIENT_CR_NAME}"
if oc get secret $CLIENT_SECRET_NAME -n rhsso >/dev/null 2>&1; then
    echo "✓ Client secret '${CLIENT_SECRET_NAME}' exists"
    CLIENT_ID_FROM_SECRET=$(oc get secret $CLIENT_SECRET_NAME -n rhsso -o jsonpath='{.data.CLIENT_ID}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$CLIENT_ID_FROM_SECRET" ]; then
        echo "  Client ID from secret: ${CLIENT_ID_FROM_SECRET}"
    fi
else
    echo "Note: Client secret '${CLIENT_SECRET_NAME}' not yet created (may be created after Trusted Artifact Signer installation)"
fi

# Step 5: Install RHTAS Operator
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
