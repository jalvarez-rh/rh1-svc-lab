#!/bin/bash

# Script to install Red Hat Trusted Artifact Signer (RHTAS) with OpenShift SSO as OIDC provider on OpenShift
# Assumes oc is installed and user is logged in as cluster-admin
# Usage: ./08-install-trusted-artifact-signer.sh

# Step 1: Get OpenShift OAuth Issuer URL
echo "Retrieving OpenShift OAuth Issuer URL..."
OIDC_ISSUER_URL=$(oc get authentication.config.openshift.io cluster -o jsonpath='{.status.oauthServerURL}' 2>/dev/null || echo "")
if [ -z "$OIDC_ISSUER_URL" ]; then
    # Fallback: try to get from OAuth route
    OAUTH_HOST=$(oc get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$OAUTH_HOST" ]; then
        OIDC_ISSUER_URL="https://${OAUTH_HOST}"
    else
        echo "Error: Could not retrieve OpenShift OAuth issuer URL"
        echo "Please ensure you are logged in as cluster-admin"
        exit 1
    fi
fi
echo "✓ OpenShift OAuth Issuer URL: $OIDC_ISSUER_URL"

# Step 2: Create OAuth Client for Trusted Artifact Signer
echo "Creating OAuth Client for Trusted Artifact Signer..."
OIDC_CLIENT_ID="trusted-artifact-signer"

# Check if OAuth client already exists
if oc get oauthclient "$OIDC_CLIENT_ID" 2>/dev/null; then
    echo "OAuth client '$OIDC_CLIENT_ID' already exists, skipping creation"
else
    cat <<EOF | oc apply -f -
apiVersion: oauth.openshift.io/v1
kind: OAuthClient
metadata:
  name: ${OIDC_CLIENT_ID}
grantMethod: auto
redirectURIs:
  - "http://localhost/auth/callback"
  - "urn:ietf:wg:oauth:2.0:oob"
secret: ""
EOF
    echo "✓ OAuth client '$OIDC_CLIENT_ID' created"
fi

# Step 3: Install RHTAS Operator
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

# Step 4: Create namespace for RHTAS components
oc create namespace trusted-artifact-signer || true

# Step 5: Deploy Securesign CR with OpenShift OIDC configuration
echo "Deploying Securesign CR with OpenShift OIDC configuration..."
echo "Using OIDC Issuer URL: $OIDC_ISSUER_URL"
echo "Using OAuth Client ID: $OIDC_CLIENT_ID"
cat <<EOF | oc apply -f -
apiVersion: rhtas.redhat.com/v1alpha1
kind: Securesign
metadata:
  name: securesign
  namespace: trusted-artifact-signer
spec:
  fulcio:
    config:
      OIDCIssuers:
      - ClientID: ${OIDC_CLIENT_ID}
        Issuer: ${OIDC_ISSUER_URL}
        IssuerURL: ${OIDC_ISSUER_URL}
        Type: email
    certificate:
      organizationName: Red Hat
      commonName: Fulcio
EOF

# Wait for RHTAS components to be ready
echo "Waiting for RHTAS components to be ready..."
MAX_WAIT=900
WAIT_COUNT=0

# Wait for components to be created first
echo "Waiting for RHTAS components to be created..."
while [ $WAIT_COUNT -lt 180 ]; do
    if oc get ctlog securesign-ctlog -n trusted-artifact-signer 2>/dev/null && \
       oc get fulcio securesign-fulcio -n trusted-artifact-signer 2>/dev/null && \
       oc get rekor securesign-rekor -n trusted-artifact-signer 2>/dev/null && \
       oc get trillian securesign-trillian -n trusted-artifact-signer 2>/dev/null && \
       oc get tuf securesign-tuf -n trusted-artifact-signer 2>/dev/null && \
       oc get securesign securesign -n trusted-artifact-signer 2>/dev/null; then
        echo "✓ All RHTAS component CRs have been created"
        break
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for component CRs to be created... (${WAIT_COUNT}s/180s)"
    fi
done

# Now wait for them to be ready with all required conditions
WAIT_COUNT=0
COMPONENTS_READY=false

echo "Waiting for all RHTAS components to reach Ready state with required conditions..."

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Check CTlog conditions: Ready, FulcioCertAvailable, ServerConfigAvailable
    CTLOG_READY=$(oc get ctlog securesign-ctlog -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    CTLOG_FULCIO_CERT=$(oc get ctlog securesign-ctlog -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="FulcioCertAvailable")].status}' 2>/dev/null || echo "")
    CTLOG_SERVER_CONFIG=$(oc get ctlog securesign-ctlog -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="ServerConfigAvailable")].status}' 2>/dev/null || echo "")
    
    # Check Fulcio conditions: Ready, FulcioCertAvailable
    FULCIO_READY=$(oc get fulcio securesign-fulcio -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    FULCIO_CERT=$(oc get fulcio securesign-fulcio -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="FulcioCertAvailable")].status}' 2>/dev/null || echo "")
    
    # Check Rekor conditions: Ready, ServerAvailable, RedisAvailable, SignerAvailable, UiAvailable
    REKOR_READY=$(oc get rekor securesign-rekor -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    REKOR_SERVER=$(oc get rekor securesign-rekor -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="ServerAvailable")].status}' 2>/dev/null || echo "")
    REKOR_REDIS=$(oc get rekor securesign-rekor -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="RedisAvailable")].status}' 2>/dev/null || echo "")
    REKOR_SIGNER=$(oc get rekor securesign-rekor -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="SignerAvailable")].status}' 2>/dev/null || echo "")
    REKOR_UI=$(oc get rekor securesign-rekor -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="UiAvailable")].status}' 2>/dev/null || echo "")
    
    # Check Trillian conditions: Ready, LogServerAvailable, LogSignerAvailable, DBAvailable
    TRILLIAN_READY=$(oc get trillian securesign-trillian -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    TRILLIAN_LOG_SERVER=$(oc get trillian securesign-trillian -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="LogServerAvailable")].status}' 2>/dev/null || echo "")
    TRILLIAN_LOG_SIGNER=$(oc get trillian securesign-trillian -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="LogSignerAvailable")].status}' 2>/dev/null || echo "")
    TRILLIAN_DB=$(oc get trillian securesign-trillian -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="DBAvailable")].status}' 2>/dev/null || echo "")
    
    # Check Tuf conditions: Ready, rekor.pub, ctfe.pub, fulcio_v1.crt.pem, repository
    TUF_READY=$(oc get tuf securesign-tuf -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    TUF_REKOR_PUB=$(oc get tuf securesign-tuf -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="rekor.pub")].status}' 2>/dev/null || echo "")
    TUF_CTFE_PUB=$(oc get tuf securesign-tuf -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="ctfe.pub")].status}' 2>/dev/null || echo "")
    TUF_FULCIO_CRT=$(oc get tuf securesign-tuf -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="fulcio_v1.crt.pem")].status}' 2>/dev/null || echo "")
    TUF_REPOSITORY=$(oc get tuf securesign-tuf -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="repository")].status}' 2>/dev/null || echo "")
    
    # Check Securesign conditions: TrillianAvailable, FulcioAvailable, RekorAvailable, CTlogAvailable, TufAvailable, MetricsAvailable
    SECURESIGN_TRILLIAN=$(oc get securesign securesign -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="TrillianAvailable")].status}' 2>/dev/null || echo "")
    SECURESIGN_FULCIO=$(oc get securesign securesign -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="FulcioAvailable")].status}' 2>/dev/null || echo "")
    SECURESIGN_REKOR=$(oc get securesign securesign -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="RekorAvailable")].status}' 2>/dev/null || echo "")
    SECURESIGN_CTLOG=$(oc get securesign securesign -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="CTlogAvailable")].status}' 2>/dev/null || echo "")
    SECURESIGN_TUF=$(oc get securesign securesign -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="TufAvailable")].status}' 2>/dev/null || echo "")
    SECURESIGN_METRICS=$(oc get securesign securesign -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="MetricsAvailable")].status}' 2>/dev/null || echo "")
    
    # Check if all conditions are True
    CTLOG_OK=false
    FULCIO_OK=false
    REKOR_OK=false
    TRILLIAN_OK=false
    TUF_OK=false
    SECURESIGN_OK=false
    
    if [ "$CTLOG_READY" = "True" ] && [ "$CTLOG_FULCIO_CERT" = "True" ] && [ "$CTLOG_SERVER_CONFIG" = "True" ]; then
        CTLOG_OK=true
    fi
    
    if [ "$FULCIO_READY" = "True" ] && [ "$FULCIO_CERT" = "True" ]; then
        FULCIO_OK=true
    fi
    
    if [ "$REKOR_READY" = "True" ] && [ "$REKOR_SERVER" = "True" ] && [ "$REKOR_REDIS" = "True" ] && \
       [ "$REKOR_SIGNER" = "True" ] && [ "$REKOR_UI" = "True" ]; then
        REKOR_OK=true
    fi
    
    if [ "$TRILLIAN_READY" = "True" ] && [ "$TRILLIAN_LOG_SERVER" = "True" ] && \
       [ "$TRILLIAN_LOG_SIGNER" = "True" ] && [ "$TRILLIAN_DB" = "True" ]; then
        TRILLIAN_OK=true
    fi
    
    if [ "$TUF_READY" = "True" ] && [ "$TUF_REKOR_PUB" = "True" ] && [ "$TUF_CTFE_PUB" = "True" ] && \
       [ "$TUF_FULCIO_CRT" = "True" ] && [ "$TUF_REPOSITORY" = "True" ]; then
        TUF_OK=true
    fi
    
    if [ "$SECURESIGN_TRILLIAN" = "True" ] && [ "$SECURESIGN_FULCIO" = "True" ] && \
       [ "$SECURESIGN_REKOR" = "True" ] && [ "$SECURESIGN_CTLOG" = "True" ] && \
       [ "$SECURESIGN_TUF" = "True" ] && [ "$SECURESIGN_METRICS" = "True" ]; then
        SECURESIGN_OK=true
    fi
    
    if [ "$CTLOG_OK" = true ] && [ "$FULCIO_OK" = true ] && [ "$REKOR_OK" = true ] && \
       [ "$TRILLIAN_OK" = true ] && [ "$TUF_OK" = true ] && [ "$SECURESIGN_OK" = true ]; then
        COMPONENTS_READY=true
        echo "✓ All RHTAS components are ready with all required conditions"
        break
    fi
    
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 10))
    if [ $((WAIT_COUNT % 60)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for RHTAS components... (${WAIT_COUNT}s/${MAX_WAIT}s)"
        echo "    CTLog: Ready=${CTLOG_READY:-Unknown}, FulcioCert=${CTLOG_FULCIO_CERT:-Unknown}, ServerConfig=${CTLOG_SERVER_CONFIG:-Unknown}"
        echo "    Fulcio: Ready=${FULCIO_READY:-Unknown}, Cert=${FULCIO_CERT:-Unknown}"
        echo "    Rekor: Ready=${REKOR_READY:-Unknown}, Server=${REKOR_SERVER:-Unknown}, Redis=${REKOR_REDIS:-Unknown}, Signer=${REKOR_SIGNER:-Unknown}, UI=${REKOR_UI:-Unknown}"
        echo "    Trillian: Ready=${TRILLIAN_READY:-Unknown}, LogServer=${TRILLIAN_LOG_SERVER:-Unknown}, LogSigner=${TRILLIAN_LOG_SIGNER:-Unknown}, DB=${TRILLIAN_DB:-Unknown}"
        echo "    Tuf: Ready=${TUF_READY:-Unknown}, rekor.pub=${TUF_REKOR_PUB:-Unknown}, ctfe.pub=${TUF_CTFE_PUB:-Unknown}, fulcio_v1.crt.pem=${TUF_FULCIO_CRT:-Unknown}, repository=${TUF_REPOSITORY:-Unknown}"
        echo "    Securesign: Trillian=${SECURESIGN_TRILLIAN:-Unknown}, Fulcio=${SECURESIGN_FULCIO:-Unknown}, Rekor=${SECURESIGN_REKOR:-Unknown}, CTlog=${SECURESIGN_CTLOG:-Unknown}, Tuf=${SECURESIGN_TUF:-Unknown}, Metrics=${SECURESIGN_METRICS:-Unknown}"
    fi
done

if [ "$COMPONENTS_READY" = false ]; then
    echo "Warning: Some RHTAS components may not be ready yet with all required conditions"
    echo "Final status check:"
    echo "  CTLog OK: $CTLOG_OK"
    echo "  Fulcio OK: $FULCIO_OK"
    echo "  Rekor OK: $REKOR_OK"
    echo "  Trillian OK: $TRILLIAN_OK"
    echo "  Tuf OK: $TUF_OK"
    echo "  Securesign OK: $SECURESIGN_OK"
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
echo "  export COSIGN_OIDC_CLIENT_ID=${OIDC_CLIENT_ID}"
echo ""
echo "Then initialize cosign: cosign initialize"
echo "And sign an image: cosign sign -y <image>"