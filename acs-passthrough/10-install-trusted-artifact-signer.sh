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
oc wait --for=condition=Available deployment/rhsso-operator -n keycloak-system --timeout=300s

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
oc wait --for=condition=Ready pod -l app=keycloak -n keycloak-system --timeout=600s

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
KEYCLOAK_HOST=$(oc get route keycloak -n keycloak-system -o jsonpath='{.spec.host}')
OIDC_ISSUER_URL="http://${KEYCLOAK_HOST}/auth/realms/trusted-artifact-signer"  # Use https in production

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
oc wait --for=condition=Available deployment -l operators.coreos.com/trusted-artifact-signer.openshift-operators -n openshift-operators --timeout=300s

# Step 7: Create namespace for RHTAS components
oc create namespace trusted-artifact-signer || true

# Step 8: Deploy Securesign CR with OIDC configuration
echo "Deploying Securesign CR..."
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
      - issuer: ${OIDC_ISSUER_URL}
        clientID: trusted-artifact-signer
        issuerURL: ${OIDC_ISSUER_URL}
        type: email
EOF

# Wait for RHTAS components to be ready
echo "Waiting for RHTAS components to be ready..."
oc wait --for=condition=Ready ctlog/securesign-sample-ctlog -n trusted-artifact-signer --timeout=600s
oc wait --for=condition=Ready fulcio/securesign-sample-fulcio -n trusted-artifact-signer --timeout=600s
oc wait --for=condition=Ready rekor/securesign-sample-rekor -n trusted-artifact-signer --timeout=600s
oc wait --for=condition=Ready trillian/securesign-sample-trillian -n trusted-artifact-signer --timeout=600s
oc wait --for=condition=Ready tuf/securesign-sample-tuf -n trusted-artifact-signer --timeout=600s

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