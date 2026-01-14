#!/bin/bash
# ACS Setup Script
# Downloads and sets up roxctl CLI and switches to local-cluster context

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[ACS-SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[ACS-SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[ACS-SETUP] ERROR:${NC} $1" >&2
    echo -e "${RED}[ACS-SETUP] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        ROXCTL_ARCH="linux"
        ;;
    aarch64|arm64)
        ROXCTL_ARCH="linux_arm64"
        ;;
    *)
        error "Unsupported architecture: $ARCH"
        ;;
esac

# Check if roxctl is available and install if not
log "Checking for roxctl CLI..."
ROXCTL_VERSION="4.9.0"
ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/${ROXCTL_VERSION}/bin/${ROXCTL_ARCH}/roxctl"
ROXCTL_TMP="/tmp/roxctl"

if command -v roxctl >/dev/null 2>&1; then
    INSTALLED_VERSION=$(roxctl version --output json 2>/dev/null | grep -oP '"version":\s*"\K[^"]+' | head -1 || echo "")
    if [ -n "$INSTALLED_VERSION" ] && [[ "$INSTALLED_VERSION" == 4.9.* ]]; then
        log "roxctl version $INSTALLED_VERSION is already installed"
    else
        log "roxctl exists but is not version 4.9, downloading version $ROXCTL_VERSION..."
        curl -k -L -o "$ROXCTL_TMP" "$ROXCTL_URL" || error "Failed to download roxctl"
        chmod +x "$ROXCTL_TMP"
        sudo mv "$ROXCTL_TMP" /usr/local/bin/roxctl || error "Failed to move roxctl to /usr/local/bin"
        log "roxctl version $ROXCTL_VERSION installed successfully"
    fi
else
    log "roxctl not found, installing version $ROXCTL_VERSION..."
    curl -k -L -o "$ROXCTL_TMP" "$ROXCTL_URL" || error "Failed to download roxctl"
    chmod +x "$ROXCTL_TMP"
    sudo mv "$ROXCTL_TMP" /usr/local/bin/roxctl || error "Failed to move roxctl to /usr/local/bin"
    log "roxctl version $ROXCTL_VERSION installed successfully"
fi

# Verify installation
if ! command -v roxctl >/dev/null 2>&1; then
    error "roxctl installation verification failed"
fi

log "roxctl CLI setup complete"

# Switch to local-cluster context
log "Switching to local-cluster context..."

# Check if oc/kubectl is available
if ! command -v oc >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
    error "oc or kubectl not found. Cannot switch context."
fi

# Use oc if available, otherwise kubectl
KUBECTL_CMD="oc"
if ! command -v oc >/dev/null 2>&1; then
    KUBECTL_CMD="kubectl"
fi

# Switch to local-cluster context
if $KUBECTL_CMD config use-context local-cluster >/dev/null 2>&1; then
    log "✓ Switched to local-cluster context"
else
    error "Failed to switch to local-cluster context. Please ensure the context exists."
fi

# Generate API token and save to ~/.bashrc
log "Generating RHACS API token..."

# Load environment variables from ~/.bashrc if not already set
if [ -z "${ROX_CENTRAL_ADDRESS:-}" ] || [ -z "${ACS_PORTAL_USERNAME:-}" ] || [ -z "${ACS_PORTAL_PASSWORD:-}" ]; then
    if [ -f ~/.bashrc ]; then
        set +u
        source ~/.bashrc
        set -u
    fi
fi

# Check if required variables are set
if [ -z "${ROX_CENTRAL_ADDRESS:-}" ] || [ -z "${ACS_PORTAL_USERNAME:-}" ] || [ -z "${ACS_PORTAL_PASSWORD:-}" ]; then
    warning "Required environment variables not found. Skipping API token generation."
    warning "Please set ROX_CENTRAL_ADDRESS, ACS_PORTAL_USERNAME, and ACS_PORTAL_PASSWORD in ~/.bashrc first."
else
    # Check if token already exists in bashrc
    if grep -q "ROX_API_TOKEN" ~/.bashrc 2>/dev/null; then
        log "ROX_API_TOKEN already exists in ~/.bashrc, skipping token generation"
    else
        # Ensure jq is available
        if ! command -v jq >/dev/null 2>&1; then
            warning "jq is required for token extraction. Installing jq..."
            if command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y jq >/dev/null 2>&1 || warning "Failed to install jq using dnf"
            elif command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y jq >/dev/null 2>&1 || warning "Failed to install jq using apt-get"
            else
                warning "Cannot install jq automatically. Please install jq manually."
            fi
        fi

        if command -v jq >/dev/null 2>&1; then
            # Generate token using curl
            set +e
            ROX_API_TOKEN=$(curl -sk \
                -u "${ACS_PORTAL_USERNAME}:${ACS_PORTAL_PASSWORD}" \
                -H "Content-Type: application/json" \
                --data-raw '{"name": "cli-admin-token", "roles": ["Admin"]}' \
                "${ROX_CENTRAL_ADDRESS}/v1/apitokens/generate" \
                | jq -r '.token' 2>/dev/null)
            TOKEN_EXIT_CODE=$?
            set -e

            if [ $TOKEN_EXIT_CODE -eq 0 ] && [ -n "$ROX_API_TOKEN" ] && [ "$ROX_API_TOKEN" != "null" ] && [ ${#ROX_API_TOKEN} -ge 20 ]; then
                # Append to ~/.bashrc
                echo "" >> ~/.bashrc
                echo "# RHACS API Token (generated by acs-setup.sh)" >> ~/.bashrc
                echo "export ROX_API_TOKEN=\"$ROX_API_TOKEN\"" >> ~/.bashrc
                log "✓ API token generated and saved to ~/.bashrc"
            else
                warning "Failed to generate API token. Please check your credentials and ROX_CENTRAL_ADDRESS."
            fi
        else
            warning "jq is not available. Cannot extract token. Please install jq and run the script again."
        fi
    fi
fi

# Deploy Secured Cluster Services to aws-us cluster
log "Deploying Secured Cluster Services to aws-us cluster..."

# Ensure we're on local-cluster to get Central information
if ! $KUBECTL_CMD config use-context local-cluster >/dev/null 2>&1; then
    error "Failed to switch to local-cluster context. Cannot retrieve Central information."
fi

RHACS_OPERATOR_NAMESPACE="stackrox"
CLUSTER_NAME="aws-us"
SECURED_CLUSTER_NAME="aws-us"

# Get Central route from local-cluster
log "Retrieving Central route from local-cluster..."
CENTRAL_ROUTE=$($KUBECTL_CMD get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$CENTRAL_ROUTE" ]; then
    error "Central route not found in namespace '$RHACS_OPERATOR_NAMESPACE' on local-cluster. Please ensure RHACS Central is installed."
fi
ROX_ENDPOINT="$CENTRAL_ROUTE"
log "✓ Central endpoint: $ROX_ENDPOINT"

# Normalize endpoint for API calls
normalize_rox_endpoint() {
    local input="$1"
    input="${input#https://}"
    input="${input#http://}"
    input="${input%/}"
    if [[ "$input" != *:* ]]; then
        input="${input}:443"
    fi
    echo "$input"
}

ROX_ENDPOINT_NORMALIZED="$(normalize_rox_endpoint "$ROX_ENDPOINT")"

# Get admin password from secret
log "Retrieving admin password from secret..."
ADMIN_PASSWORD_B64=$($KUBECTL_CMD get secret central-htpasswd -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
if [ -z "$ADMIN_PASSWORD_B64" ]; then
    error "Admin password secret 'central-htpasswd' not found in namespace '$RHACS_OPERATOR_NAMESPACE'"
fi
ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)
if [ -z "$ADMIN_PASSWORD" ]; then
    error "Failed to decode admin password from secret"
fi
log "✓ Admin password retrieved"

# Check if SecuredCluster already exists in aws-us cluster
$KUBECTL_CMD config use-context aws-us >/dev/null 2>&1 || error "Failed to switch to aws-us context"

if $KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    log "SecuredCluster '$SECURED_CLUSTER_NAME' already exists in aws-us cluster, skipping setup"
else
    # Ensure namespace exists in aws-us cluster
    log "Ensuring namespace '$RHACS_OPERATOR_NAMESPACE' exists in aws-us cluster..."
    if ! $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        $KUBECTL_CMD create namespace "$RHACS_OPERATOR_NAMESPACE" || error "Failed to create namespace"
        log "✓ Namespace created"
    else
        log "✓ Namespace exists"
    fi

    # Generate init bundle
    log "Generating init bundle for cluster: $CLUSTER_NAME"
    INIT_BUNDLE_OUTPUT=$(roxctl -e "$ROX_ENDPOINT_NORMALIZED" \
      central init-bundles generate "$CLUSTER_NAME" \
      --output-secrets cluster_init_bundle.yaml \
      --password "$ADMIN_PASSWORD" \
      --insecure-skip-tls-verify 2>&1) || INIT_BUNDLE_EXIT_CODE=$?
    
    if echo "$INIT_BUNDLE_OUTPUT" | grep -q "AlreadyExists"; then
        log "Init bundle already exists in RHACS Central, using existing bundle"
        # Try to retrieve existing bundle or create a new one with different name
        INIT_BUNDLE_OUTPUT=$(roxctl -e "$ROX_ENDPOINT_NORMALIZED" \
          central init-bundles generate "${CLUSTER_NAME}-$(date +%s)" \
          --output-secrets cluster_init_bundle.yaml \
          --password "$ADMIN_PASSWORD" \
          --insecure-skip-tls-verify 2>&1) || warning "Failed to generate new init bundle"
    fi

    if [ ! -f cluster_init_bundle.yaml ]; then
        error "Failed to generate init bundle. roxctl output: ${INIT_BUNDLE_OUTPUT:0:500}"
    fi
    log "✓ Init bundle generated"

    # Apply init bundle secrets to aws-us cluster
    log "Applying init bundle secrets to aws-us cluster..."
    $KUBECTL_CMD apply -f cluster_init_bundle.yaml -n "$RHACS_OPERATOR_NAMESPACE" || error "Failed to apply init bundle secrets"
    log "✓ Init bundle secrets applied"

    # Create SecuredCluster resource in aws-us cluster
    log "Creating SecuredCluster resource in aws-us cluster..."
    cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: platform.stackrox.io/v1alpha1
kind: SecuredCluster
metadata:
  name: $SECURED_CLUSTER_NAME
  namespace: $RHACS_OPERATOR_NAMESPACE
spec:
  clusterName: "$CLUSTER_NAME"
  auditLogs:
    collection: Auto
  admissionControl:
    enforcement: Enabled
    bypass: BreakGlassAnnotation
    failurePolicy: Ignore
  scannerV4:
    scannerComponent: Default
  processBaselines:
    autoLock: Enabled
EOF
    
    log "✓ SecuredCluster resource created"

    # Clean up temporary files
    rm -f cluster_init_bundle.yaml

    log "Secured Cluster Services deployment initiated for aws-us cluster"
    log "The SecuredCluster will connect to Central running on local-cluster"
fi

log "ACS setup complete"
