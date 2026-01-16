#!/bin/bash

# Script to install Red Hat Trusted Artifact Signer (RHTAS) with Red Hat SSO as OIDC provider on OpenShift
# Assumes oc is installed and user is logged in as cluster-admin
# Usage: ./10-install-trusted-artifact-signer.sh

# Step 1: Install Red Hat Single Sign-On (RH SSO) Operator
echo "Installing RH SSO Operator..."
oc create namespace keycloak-system || true

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: keycloak-operator-group
  namespace: keycloak-system
spec:
  targetNamespaces:
  - keycloak-system
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhsso-operator
  namespace: keycloak-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhsso-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for RH SSO Operator to be ready
echo "Waiting for RH SSO Operator to be ready..."
MAX_WAIT=300
WAIT_COUNT=0
OPERATOR_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Check for operator deployment (name may vary)
    if oc get deployment -n keycloak-system -l operators.coreos.com/rhsso-operator.keycloak-system 2>/dev/null | grep -q rhsso; then
        DEPLOYMENT_NAME=$(oc get deployment -n keycloak-system -l operators.coreos.com/rhsso-operator.keycloak-system -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$DEPLOYMENT_NAME" ]; then
            if oc wait --for=condition=Available "deployment/$DEPLOYMENT_NAME" -n keycloak-system --timeout=10s 2>/dev/null; then
                OPERATOR_READY=true
                echo "✓ RH SSO Operator is ready"
                break
            fi
        fi
    fi
    
    # Also check for CSV
    CSV_NAME=$(oc get csv -n keycloak-system -o jsonpath='{.items[?(@.spec.displayName=="Red Hat Single Sign-On Operator")].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n keycloak-system -o name 2>/dev/null | grep rhsso | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    fi
    
    if [ -n "$CSV_NAME" ]; then
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n keycloak-system -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            OPERATOR_READY=true
            echo "✓ RH SSO Operator CSV is ready: $CSV_NAME"
            break
        fi
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for RH SSO Operator... (${WAIT_COUNT}s/${MAX_WAIT}s)"
    fi
done

if [ "$OPERATOR_READY" = false ]; then
    echo "Warning: RH SSO Operator may not be fully ready, but proceeding..."
fi

# Wait for Keycloak CRDs to be available
echo "Waiting for Keycloak CRDs to be available..."
MAX_WAIT=120
WAIT_COUNT=0
CRDS_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if oc api-resources | grep -q "keycloak.org/v1alpha1" && oc get crd keycloaks.keycloak.org 2>/dev/null; then
        CRDS_READY=true
        echo "✓ Keycloak CRDs are available"
        break
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$CRDS_READY" = false ]; then
    echo "Error: Keycloak CRDs not available after ${MAX_WAIT}s"
    exit 1
fi

# Step 2: Deploy Keycloak instance with internal DB (H2 for simplicity)
echo "Deploying Keycloak instance..."
cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: keycloak-system
spec:
  instances: 1
  db:
    vendor: h2
  http:
    httpEnabled: true  # For simplicity; use TLS in production
EOF

# Wait for Keycloak to be ready
echo "Waiting for Keycloak to be ready..."
MAX_WAIT=600
WAIT_COUNT=0
KEYCLOAK_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if oc get pod -l app=keycloak -n keycloak-system 2>/dev/null | grep -q Running; then
        if oc wait --for=condition=Ready pod -l app=keycloak -n keycloak-system --timeout=10s 2>/dev/null; then
            KEYCLOAK_READY=true
            echo "✓ Keycloak pod is ready"
            break
        fi
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for Keycloak... (${WAIT_COUNT}s/${MAX_WAIT}s)"
    fi
done

if [ "$KEYCLOAK_READY" = false ]; then
    echo "Error: Keycloak pod not ready after ${MAX_WAIT}s"
    exit 1
fi

# Wait for Keycloak route to be created
echo "Waiting for Keycloak route..."
MAX_WAIT=120
WAIT_COUNT=0
ROUTE_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if oc get route keycloak -n keycloak-system 2>/dev/null | grep -q keycloak; then
        ROUTE_READY=true
        echo "✓ Keycloak route exists"
        break
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$ROUTE_READY" = false ]; then
    echo "Error: Keycloak route not found after ${MAX_WAIT}s"
    exit 1
fi

# Step 3: Create Realm for RHTAS
echo "Creating Keycloak Realm..."
cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakRealm
metadata:
  name: trusted-artifact-signer
  namespace: keycloak-system
spec:
  realm:
    realm: trusted-artifact-signer
    enabled: true
    displayName: Trusted Artifact Signer Realm
EOF

# Step 4: Create Client for RHTAS (public client for OIDC)
echo "Creating Keycloak Client..."
cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakClient
metadata:
  name: trusted-artifact-signer
  namespace: keycloak-system
spec:
  realmSelector:
    matchLabels:
      realm: trusted-artifact-signer
  client:
    clientId: trusted-artifact-signer
    clientAuthenticatorType: none  # Public client
    standardFlowEnabled: true
    validRedirectUris:
    - "*"
    webOrigins:
    - "+"
EOF

# Step 5: Get OIDC Issuer URL
echo "Retrieving OIDC Issuer URL..."
KEYCLOAK_HOST=$(oc get route keycloak -n keycloak-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$KEYCLOAK_HOST" ]; then
    echo "Error: Could not retrieve Keycloak route host"
    exit 1
fi
OIDC_ISSUER_URL="http://${KEYCLOAK_HOST}/auth/realms/trusted-artifact-signer"  # Use https in production
echo "✓ OIDC Issuer URL: $OIDC_ISSUER_URL"

# Step 6: Install RHTAS Operator
echo "Installing RHTAS Operator..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: trusted-artifact-signer
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: trusted-artifact-signer
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for RHTAS Operator to be ready
echo "Waiting for RHTAS Operator to be ready..."
MAX_WAIT=300
WAIT_COUNT=0
RHTAS_OPERATOR_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    CSV_NAME=$(oc get csv -n openshift-operators -o jsonpath='{.items[?(@.spec.displayName=="Trusted Artifact Signer Operator")].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n openshift-operators -o name 2>/dev/null | grep trusted-artifact-signer | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    fi
    
    if [ -n "$CSV_NAME" ]; then
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            RHTAS_OPERATOR_READY=true
            echo "✓ RHTAS Operator CSV is ready: $CSV_NAME"
            break
        fi
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for RHTAS Operator... (${WAIT_COUNT}s/${MAX_WAIT}s)"
    fi
done

if [ "$RHTAS_OPERATOR_READY" = false ]; then
    echo "Warning: RHTAS Operator may not be fully ready, but proceeding..."
fi

# Wait for RHTAS CRDs to be available
echo "Waiting for RHTAS CRDs to be available..."
MAX_WAIT=120
WAIT_COUNT=0
RHTAS_CRDS_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if oc get crd securesigns.rhtas.redhat.com 2>/dev/null; then
        RHTAS_CRDS_READY=true
        echo "✓ RHTAS CRDs are available"
        break
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$RHTAS_CRDS_READY" = false ]; then
    echo "Error: RHTAS CRDs not available after ${MAX_WAIT}s"
    exit 1
fi

# Step 7: Create namespace for RHTAS components
oc create namespace trusted-artifact-signer || true

# Step 8: Deploy Securesign CR with OIDC configuration
echo "Deploying Securesign CR..."
echo "Using OIDC Issuer URL: $OIDC_ISSUER_URL"
cat <<EOF | oc apply -f -
apiVersion: rhtas.redhat.com/v1alpha1
kind: Securesign
metadata:
  name: securesign-sample
  namespace: trusted-artifact-signer
spec:
  fulcio:
    config:
      OIDCIssuers:
      - Issuer: ${OIDC_ISSUER_URL}
        ClientID: trusted-artifact-signer
        IssuerURL: ${OIDC_ISSUER_URL}
        Type: email
    certificate:
      organizationName: Red Hat
      commonName: Fulcio
EOF

# Wait for RHTAS components to be ready
echo "Waiting for RHTAS components to be ready..."
MAX_WAIT=600
WAIT_COUNT=0

# Wait for components to be created first
echo "Waiting for RHTAS components to be created..."
while [ $WAIT_COUNT -lt 120 ]; do
    if oc get ctlog securesign-sample-ctlog -n trusted-artifact-signer 2>/dev/null && \
       oc get fulcio securesign-sample-fulcio -n trusted-artifact-signer 2>/dev/null && \
       oc get rekor securesign-sample-rekor -n trusted-artifact-signer 2>/dev/null; then
        break
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

# Now wait for them to be ready
WAIT_COUNT=0
COMPONENTS_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    CTLOG_READY=$(oc get ctlog securesign-sample-ctlog -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    FULCIO_READY=$(oc get fulcio securesign-sample-fulcio -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    REKOR_READY=$(oc get rekor securesign-sample-rekor -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    TRILLIAN_READY=$(oc get trillian securesign-sample-trillian -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    TUF_READY=$(oc get tuf securesign-sample-tuf -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    
    if [ "$CTLOG_READY" = "True" ] && [ "$FULCIO_READY" = "True" ] && [ "$REKOR_READY" = "True" ] && \
       [ "$TRILLIAN_READY" = "True" ] && [ "$TUF_READY" = "True" ]; then
        COMPONENTS_READY=true
        echo "✓ All RHTAS components are ready"
        break
    fi
    
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 10))
    if [ $((WAIT_COUNT % 60)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for RHTAS components... (${WAIT_COUNT}s/${MAX_WAIT}s)"
        echo "    CTLog: ${CTLOG_READY:-Unknown}, Fulcio: ${FULCIO_READY:-Unknown}, Rekor: ${REKOR_READY:-Unknown}"
    fi
done

if [ "$COMPONENTS_READY" = false ]; then
    echo "Warning: Some RHTAS components may not be ready yet"
fi

echo "Installation complete!"
echo "RHTAS is now installed and ready to use."
echo ""
echo "To sign an image, set up the following environment variables:"
echo "  export FULCIO_URL=\$(oc get fulcio -o jsonpath='{.items[0].status.url}' -n trusted-artifact-signer)"
echo "  export REKOR_URL=\$(oc get rekor -o jsonpath='{.items[0].status.url}' -n trusted-artifact-signer)"
echo "  export TUF_URL=\$(oc get tuf -o jsonpath='{.items[0].status.url}' -n trusted-artifact-signer)"
echo "  export COSIGN_FULCIO_URL=\$FULCIO_URL"
echo "  export COSIGN_REKOR_URL=\$REKOR_URL"
echo "  export COSIGN_MIRROR=\$TUF_URL"
echo "  export COSIGN_ROOT=\$TUF_URL/root.json"
echo "  export COSIGN_OIDC_ISSUER=${OIDC_ISSUER_URL}"
echo "  export COSIGN_OIDC_CLIENT_ID=trusted-artifact-signer"
echo ""
echo "Then initialize cosign: cosign initialize"
echo "And sign an image: cosign sign -y <image>"