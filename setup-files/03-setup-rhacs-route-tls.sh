#!/bin/bash
# RHACS Route TLS Setup Script
# Creates a TLS certificate for RHACS Central using cert-manager
# Creates the central-default-tls-cert secret in rhacs-operator namespace

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
    echo -e "${GREEN}[RHACS-TLS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-TLS]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-TLS] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-TLS] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
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

# Check if cert-manager is available
log "Checking cert-manager availability..."
if ! oc get crd certificates.cert-manager.io &>/dev/null; then
    error "cert-manager CRDs not found. Please run script 02-install-cert-manager.sh first."
fi
log "✓ cert-manager CRDs available"

# Check if ClusterIssuer exists
CLUSTERISSUER_NAME="letsencrypt-production-aws"
if ! oc get clusterissuer "$CLUSTERISSUER_NAME" &>/dev/null; then
    error "ClusterIssuer '$CLUSTERISSUER_NAME' not found. Please ensure it exists."
fi
log "✓ ClusterIssuer '$CLUSTERISSUER_NAME' found"

# Set namespace
RHACS_OPERATOR_NAMESPACE="rhacs-operator"

# Ensure rhacs-operator namespace exists
log "Ensuring namespace '$RHACS_OPERATOR_NAMESPACE' exists..."
if ! oc get namespace "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    log "Creating namespace '$RHACS_OPERATOR_NAMESPACE'..."
    oc create namespace "$RHACS_OPERATOR_NAMESPACE" || error "Failed to create namespace"
fi
log "✓ Namespace '$RHACS_OPERATOR_NAMESPACE' exists"

# Get cluster base domain for DNS name from existing routes
log "Determining certificate DNS names..."
CLUSTER_DOMAIN=""

# Try to extract domain from console route
CONSOLE_ROUTE=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$CONSOLE_ROUTE" ]; then
    # Extract domain from console route (e.g., console-openshift-console.apps.cluster-bt6rr.dynamic.redhatworkshops.io)
    # Remove everything up to and including ".apps." to get the base domain
    # Pattern: <subdomain>.apps.<domain> -> extract <domain>
    CLUSTER_DOMAIN=$(echo "$CONSOLE_ROUTE" | sed 's/^[^.]*\.apps\.//')
    if [ -n "$CLUSTER_DOMAIN" ] && [ "$CLUSTER_DOMAIN" != "$CONSOLE_ROUTE" ]; then
        log "✓ Extracted domain from console route: $CLUSTER_DOMAIN"
    else
        CLUSTER_DOMAIN=""
    fi
fi

# If that didn't work, try DNS config
if [ -z "$CLUSTER_DOMAIN" ]; then
    CLUSTER_DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null || echo "")
    if [ -n "$CLUSTER_DOMAIN" ]; then
        log "✓ Cluster domain from DNS config: $CLUSTER_DOMAIN"
    fi
fi

# If still no domain, try ingress config
if [ -z "$CLUSTER_DOMAIN" ]; then
    CLUSTER_DOMAIN=$(oc get ingress.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
    if [ -n "$CLUSTER_DOMAIN" ]; then
        log "✓ Cluster domain from ingress config: $CLUSTER_DOMAIN"
    fi
fi

if [ -z "$CLUSTER_DOMAIN" ]; then
    error "Could not determine cluster domain. Please ensure cluster routes are accessible."
fi

# Construct Central DNS name: central.apps.<domain>
CENTRAL_DNS_NAME="central.apps.${CLUSTER_DOMAIN}"
CERT_DNS_NAMES=("$CENTRAL_DNS_NAME")
log "✓ Central DNS name: $CENTRAL_DNS_NAME"

log "Certificate will be valid for: ${CERT_DNS_NAMES[*]}"

# Certificate resource name
CERT_NAME="rhacs-central-tls-cert"
CERT_SECRET_NAME="rhacs-central-tls-secret"

# Check if certificate already exists
if oc get certificate "$CERT_NAME" -n "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    log "Certificate '$CERT_NAME' already exists, checking status..."
    CERT_READY=$(oc get certificate "$CERT_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "$CERT_READY" = "True" ]; then
        log "✓ Certificate is Ready"
    else
        log "Certificate exists but not ready (status: $CERT_READY), waiting..."
    fi
else
    log "Creating Certificate resource..."
    
    # Build DNS names YAML section
    DNS_NAMES_YAML=""
    for dns_name in "${CERT_DNS_NAMES[@]}"; do
        DNS_NAMES_YAML="${DNS_NAMES_YAML}  - ${dns_name}"$'\n'
    done
    
    # Create Certificate resource
    cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CERT_NAME
  namespace: $RHACS_OPERATOR_NAMESPACE
spec:
  secretName: $CERT_SECRET_NAME
  dnsNames:
${DNS_NAMES_YAML}  issuerRef:
    name: $CLUSTERISSUER_NAME
    kind: ClusterIssuer
EOF
    
    log "✓ Certificate resource created"
fi

# Wait for certificate to be ready
log "Waiting for certificate to be ready..."
log "  Note: Certificate provisioning typically takes 60-120 seconds"
log "  This includes DNS validation and certificate issuance"
log ""
MAX_WAIT=300
WAIT_COUNT=0
CERT_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Check if certificate resource exists
    if ! oc get certificate "$CERT_NAME" -n "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            log "  Still waiting... (${WAIT_COUNT}s/${MAX_WAIT}s) - Certificate resource not found yet"
        fi
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        continue
    fi
    
    # Get certificate status - check if status.conditions exists first
    CERT_HAS_CONDITIONS=$(oc get certificate "$CERT_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions}' 2>/dev/null | wc -c)
    CERT_STATUS=""
    CERT_REASON=""
    
    if [ "$CERT_HAS_CONDITIONS" -gt 2 ]; then
        # Status conditions exist, get the Ready condition
        CERT_STATUS=$(oc get certificate "$CERT_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        CERT_REASON=$(oc get certificate "$CERT_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
    fi
    
    if [ "$CERT_STATUS" = "True" ]; then
        CERT_READY=true
        log "✓ Certificate is Ready"
        break
    fi
    
    # Get additional diagnostic info
    CERT_REQ_NAME=$(oc get certificaterequest -n "$RHACS_OPERATOR_NAMESPACE" -l "cert-manager.io/certificate-name=$CERT_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    CHALLENGE_STATUS=""
    if [ -n "$CERT_REQ_NAME" ]; then
        CHALLENGE_STATUS=$(oc get certificaterequest "$CERT_REQ_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
    fi
    
    # Check for ACME challenges (for Let's Encrypt)
    ACME_ORDER_NAME=$(oc get order -n "$RHACS_OPERATOR_NAMESPACE" -l "acme.cert-manager.io/certificate-name=$CERT_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    ACME_STATUS=""
    if [ -n "$ACME_ORDER_NAME" ]; then
        ACME_STATUS=$(oc get order "$ACME_ORDER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    fi
    
    # Show progress every 30 seconds with cleaner status
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        STATUS_MSG=""
        if [ "$CERT_STATUS" = "True" ]; then
            STATUS_MSG="Status: Ready"
        elif [ -n "$CERT_REASON" ] && [ "$CERT_REASON" != "" ] && [ "$CERT_REASON" != "DoesNotExist" ]; then
            STATUS_MSG="Status: $CERT_REASON"
        elif [ -n "$ACME_STATUS" ] && [ "$ACME_STATUS" != "" ]; then
            STATUS_MSG="ACME Order: $ACME_STATUS"
        elif [ -n "$CHALLENGE_STATUS" ] && [ "$CHALLENGE_STATUS" != "" ]; then
            STATUS_MSG="CertificateRequest: $CHALLENGE_STATUS"
        elif [ "$CERT_HAS_CONDITIONS" -le 2 ]; then
            STATUS_MSG="Status: Processing (cert-manager is working on it)"
        elif [ -n "$CERT_STATUS" ] && [ "$CERT_STATUS" != "" ]; then
            STATUS_MSG="Status: $CERT_STATUS"
        else
            STATUS_MSG="Status: Processing (cert-manager is working on it)"
        fi
        log "  Still waiting... (${WAIT_COUNT}s/${MAX_WAIT}s) - $STATUS_MSG"
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$CERT_READY" = false ]; then
    warning "Certificate did not become ready within ${MAX_WAIT} seconds"
    
    # Check if certificate resource exists
    if ! oc get certificate "$CERT_NAME" -n "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
        error "Certificate resource '$CERT_NAME' was not created. Check if cert-manager is running: oc get pods -n cert-manager"
    fi
    
    # Get detailed status
    CERT_REASON=$(oc get certificate "$CERT_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "Unknown")
    CERT_MESSAGE=$(oc get certificate "$CERT_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
    
    # Check CertificateRequest
    CERT_REQ_NAME=$(oc get certificaterequest -n "$RHACS_OPERATOR_NAMESPACE" -l "cert-manager.io/certificate-name=$CERT_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$CERT_REQ_NAME" ]; then
        CERT_REQ_STATUS=$(oc get certificaterequest "$CERT_REQ_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        CERT_REQ_REASON=$(oc get certificaterequest "$CERT_REQ_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
        warning "CertificateRequest '$CERT_REQ_NAME' status: $CERT_REQ_STATUS, reason: $CERT_REQ_REASON"
    fi
    
    if [ -n "$CERT_MESSAGE" ] && [ "$CERT_MESSAGE" != "" ]; then
        warning "Certificate status reason: $CERT_REASON"
        warning "Certificate status message: $CERT_MESSAGE"
    fi
    
    log ""
    log "To troubleshoot, check:"
    log "  oc describe certificate $CERT_NAME -n $RHACS_OPERATOR_NAMESPACE"
    if [ -n "$CERT_REQ_NAME" ]; then
        log "  oc describe certificaterequest $CERT_REQ_NAME -n $RHACS_OPERATOR_NAMESPACE"
    fi
    log "  oc logs -n cert-manager -l app=cert-manager --tail=50"
    error "Certificate is not ready. See troubleshooting commands above."
fi

# Verify the cert-manager secret exists
log "Verifying cert-manager secret exists..."
if ! oc get secret "$CERT_SECRET_NAME" -n "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    error "Secret '$CERT_SECRET_NAME' not found in namespace '$RHACS_OPERATOR_NAMESPACE'"
fi
log "✓ Cert-manager secret '$CERT_SECRET_NAME' found"

# Extract certificate and key from cert-manager secret
log "Extracting certificate and key from cert-manager secret..."
CERT_DATA=$(oc get secret "$CERT_SECRET_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || echo "")
KEY_DATA=$(oc get secret "$CERT_SECRET_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.tls\.key}' 2>/dev/null || echo "")

if [ -z "$CERT_DATA" ] || [ -z "$KEY_DATA" ]; then
    error "Failed to extract certificate or key from secret '$CERT_SECRET_NAME'"
fi

# Decode base64 data
CERT_CONTENT=$(echo "$CERT_DATA" | base64 -d)
KEY_CONTENT=$(echo "$KEY_DATA" | base64 -d)

# Create the central-default-tls-cert secret
CENTRAL_TLS_SECRET_NAME="central-default-tls-cert"
log "Creating '$CENTRAL_TLS_SECRET_NAME' secret in namespace '$RHACS_OPERATOR_NAMESPACE'..."

# Delete existing secret if it exists
oc delete secret "$CENTRAL_TLS_SECRET_NAME" -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null && log "  Deleted existing secret" || log "  No existing secret found"

# Create secret using the certificate and key
# Write to temporary files first
TEMP_CERT=$(mktemp)
TEMP_KEY=$(mktemp)
echo "$CERT_CONTENT" > "$TEMP_CERT"
echo "$KEY_CONTENT" > "$TEMP_KEY"

oc create secret tls "$CENTRAL_TLS_SECRET_NAME" \
    --cert="$TEMP_CERT" \
    --key="$TEMP_KEY" \
    -n "$RHACS_OPERATOR_NAMESPACE" || error "Failed to create secret"

# Clean up temporary files
rm -f "$TEMP_CERT" "$TEMP_KEY"

log "✓ Secret '$CENTRAL_TLS_SECRET_NAME' created successfully"

# Verify the secret
log "Verifying secret contents..."
SECRET_CERT=$(oc get secret "$CENTRAL_TLS_SECRET_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || echo "")
SECRET_KEY=$(oc get secret "$CENTRAL_TLS_SECRET_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.tls\.key}' 2>/dev/null || echo "")

if [ -z "$SECRET_CERT" ] || [ -z "$SECRET_KEY" ]; then
    error "Secret '$CENTRAL_TLS_SECRET_NAME' was created but does not contain expected data"
fi

log "✓ Secret verified"

# Display certificate information
log ""
log "========================================================="
log "RHACS TLS Certificate Setup Completed!"
log "========================================================="
log "Namespace: $RHACS_OPERATOR_NAMESPACE"
log "Certificate Resource: $CERT_NAME"
log "Cert-Manager Secret: $CERT_SECRET_NAME"
log "Central TLS Secret: $CENTRAL_TLS_SECRET_NAME"
log "DNS Names: ${CERT_DNS_NAMES[*]}"
log "========================================================="
log ""
log "The 'central-default-tls-cert' secret is ready in the"
log "rhacs-operator namespace and will be used when RHACS"
log "Central is installed."
log ""

