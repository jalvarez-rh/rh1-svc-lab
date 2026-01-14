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
    # Try to get version - handle both plain text and JSON output
    INSTALLED_VERSION=$(roxctl version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    
    # If that didn't work, try JSON format
    if [ -z "$INSTALLED_VERSION" ]; then
        INSTALLED_VERSION=$(roxctl version --output json 2>/dev/null | grep -oE '"version":\s*"[^"]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    fi
    
    if [ -n "$INSTALLED_VERSION" ] && [[ "$INSTALLED_VERSION" == 4.9.* ]]; then
        log "roxctl version $INSTALLED_VERSION is already installed"
    else
        log "roxctl exists but is not version 4.9 (found: ${INSTALLED_VERSION:-unknown}), downloading version $ROXCTL_VERSION..."
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

# Get Central endpoint from environment or route
log "Retrieving Central endpoint..."
if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
    if [ -f ~/.bashrc ]; then
        set +u
        source ~/.bashrc
        set -u
    fi
fi

if [ -n "${ROX_CENTRAL_ADDRESS:-}" ]; then
    ROX_ENDPOINT="${ROX_CENTRAL_ADDRESS#https://}"
    ROX_ENDPOINT="${ROX_ENDPOINT#http://}"
    log "✓ Central endpoint from environment: $ROX_ENDPOINT"
else
    # Fallback: get from route
    CENTRAL_ROUTE=$($KUBECTL_CMD get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -z "$CENTRAL_ROUTE" ]; then
        error "Central route not found and ROX_CENTRAL_ADDRESS not set. Please ensure RHACS Central is installed or set ROX_CENTRAL_ADDRESS in ~/.bashrc"
    fi
    ROX_ENDPOINT="$CENTRAL_ROUTE"
    log "✓ Central endpoint from route: $ROX_ENDPOINT"
fi

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

# Get admin password from environment variables
log "Retrieving admin password from environment..."
if [ -z "${ACS_PORTAL_PASSWORD:-}" ]; then
    if [ -f ~/.bashrc ]; then
        set +u
        source ~/.bashrc
        set -u
    fi
fi

if [ -z "${ACS_PORTAL_PASSWORD:-}" ]; then
    error "ACS_PORTAL_PASSWORD not found. Please set it in ~/.bashrc"
fi

ADMIN_PASSWORD="$ACS_PORTAL_PASSWORD"
log "✓ Admin password retrieved from environment"

# Generate init bundle while still on local-cluster
log "Generating init bundle for cluster: $CLUSTER_NAME (while on local-cluster)..."
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

# Now switch to aws-us cluster for deployment
log "Switching to aws-us context for deployment..."
$KUBECTL_CMD config use-context aws-us >/dev/null 2>&1 || error "Failed to switch to aws-us context"
log "✓ Switched to aws-us context"

# Check if SecuredCluster already exists in aws-us cluster
if $KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    log "SecuredCluster '$SECURED_CLUSTER_NAME' already exists in aws-us cluster, skipping setup"
    rm -f cluster_init_bundle.yaml
else
    # Ensure namespace exists in aws-us cluster
    log "Ensuring namespace '$RHACS_OPERATOR_NAMESPACE' exists in aws-us cluster..."
    if ! $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        $KUBECTL_CMD create namespace "$RHACS_OPERATOR_NAMESPACE" || error "Failed to create namespace"
        log "✓ Namespace created"
    else
        log "✓ Namespace exists"
    fi

    # Check if SecuredCluster CRD exists, install operator if needed
    log "Checking if SecuredCluster CRD is installed..."
    if ! $KUBECTL_CMD get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
        log "SecuredCluster CRD not found. Installing RHACS operator..."
        
        # Create OperatorGroup if it doesn't exist
        if ! $KUBECTL_CMD get operatorgroup -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            log "Creating OperatorGroup..."
            cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhacs-operator-group
  namespace: $RHACS_OPERATOR_NAMESPACE
spec:
  targetNamespaces:
    - $RHACS_OPERATOR_NAMESPACE
EOF
            log "✓ OperatorGroup created"
        fi
        
        # Create Subscription for RHACS operator
        log "Creating RHACS operator subscription..."
        cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhacs-operator
  namespace: $RHACS_OPERATOR_NAMESPACE
spec:
  channel: stable
  name: rhacs-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
        log "✓ Operator subscription created"
        
        # Wait for CRD to be available
        log "Waiting for SecuredCluster CRD to be installed..."
        local wait_count=0
        local max_wait=120
        while ! $KUBECTL_CMD get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; do
            if [ $wait_count -ge $max_wait ]; then
                error "Timeout waiting for SecuredCluster CRD to be installed"
            fi
            sleep 2
            wait_count=$((wait_count + 1))
            if [ $((wait_count % 10)) -eq 0 ]; then
                log "  Still waiting for CRD... ($wait_count/${max_wait}s)"
            fi
        done
        log "✓ SecuredCluster CRD installed"
    else
        log "✓ SecuredCluster CRD found"
    fi

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
