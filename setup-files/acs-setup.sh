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

RHACS_OPERATOR_NAMESPACE="rhacs-operator"
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
    # Strip protocol and path, keep only host:port
    ROX_ENDPOINT="${ROX_CENTRAL_ADDRESS#https://}"
    ROX_ENDPOINT="${ROX_ENDPOINT#http://}"
    # Strip any path (everything after first /)
    ROX_ENDPOINT="${ROX_ENDPOINT%%/*}"
    # Ensure port is present (default to 443 for HTTPS)
    if [[ "$ROX_ENDPOINT" != *:* ]]; then
        ROX_ENDPOINT="${ROX_ENDPOINT}:443"
    fi
    log "✓ Central endpoint from environment: $ROX_ENDPOINT"
else
    # Fallback: get from route (check both rhacs-operator and common namespaces)
    CENTRAL_ROUTE=$($KUBECTL_CMD get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -z "$CENTRAL_ROUTE" ]; then
        # Try openshift-operators as fallback
        CENTRAL_ROUTE=$($KUBECTL_CMD get route central -n openshift-operators -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    fi
    if [ -z "$CENTRAL_ROUTE" ]; then
        error "Central route not found and ROX_CENTRAL_ADDRESS not set. Please ensure RHACS Central is installed or set ROX_CENTRAL_ADDRESS in ~/.bashrc"
    fi
    ROX_ENDPOINT="$CENTRAL_ROUTE"
    log "✓ Central endpoint from route: $ROX_ENDPOINT"
fi

# Normalize endpoint for API calls (strip protocol, path, ensure port)
normalize_rox_endpoint() {
    local input="$1"
    # Strip protocol
    input="${input#https://}"
    input="${input#http://}"
    # Strip any path (everything after first /)
    input="${input%%/*}"
    # Strip trailing slash
    input="${input%/}"
    # Ensure port is present
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

# Create init-bundles directory if it doesn't exist
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_BUNDLES_DIR="${SCRIPT_DIR}/init-bundles"
mkdir -p "$INIT_BUNDLES_DIR"
INIT_BUNDLE_FILE="${INIT_BUNDLES_DIR}/${CLUSTER_NAME}-init-bundle.yaml"

INIT_BUNDLE_OUTPUT=$(roxctl -e "$ROX_ENDPOINT_NORMALIZED" \
  central init-bundles generate "$CLUSTER_NAME" \
  --output-secrets "$INIT_BUNDLE_FILE" \
  --password "$ADMIN_PASSWORD" \
  --insecure-skip-tls-verify 2>&1) || INIT_BUNDLE_EXIT_CODE=$?

if echo "$INIT_BUNDLE_OUTPUT" | grep -q "AlreadyExists"; then
    log "Init bundle already exists in RHACS Central, using existing bundle"
    # Try to retrieve existing bundle or create a new one with different name
    INIT_BUNDLE_FILE="${INIT_BUNDLES_DIR}/${CLUSTER_NAME}-init-bundle-$(date +%s).yaml"
    INIT_BUNDLE_OUTPUT=$(roxctl -e "$ROX_ENDPOINT_NORMALIZED" \
      central init-bundles generate "${CLUSTER_NAME}-$(date +%s)" \
      --output-secrets "$INIT_BUNDLE_FILE" \
      --password "$ADMIN_PASSWORD" \
      --insecure-skip-tls-verify 2>&1) || warning "Failed to generate new init bundle"
fi

if [ ! -f "$INIT_BUNDLE_FILE" ]; then
    error "Failed to generate init bundle. roxctl output: ${INIT_BUNDLE_OUTPUT:0:500}"
fi
log "✓ Init bundle generated and saved to: $INIT_BUNDLE_FILE"

# Now switch to aws-us cluster for deployment
log "Switching to aws-us context for deployment..."
$KUBECTL_CMD config use-context aws-us >/dev/null 2>&1 || error "Failed to switch to aws-us context"
log "✓ Switched to aws-us context"

# Check if SecuredCluster actually exists and operator is properly installed
SECURED_CLUSTER_EXISTS=false
OPERATOR_INSTALLED=false

# Check if SecuredCluster CRD exists (operator must be installed)
if $KUBECTL_CMD get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
    OPERATOR_INSTALLED=true
    log "SecuredCluster CRD found, operator appears to be installed"
    
    # Check if operator pods are actually running
    CSV_NAME=$($KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
    if [ -n "$CSV_NAME" ] && [ "$CSV_NAME" != "" ]; then
        CSV_PHASE=$($KUBECTL_CMD get csv "$CSV_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            log "Operator CSV is in Succeeded phase"
        else
            log "Operator CSV phase: ${CSV_PHASE:-unknown}, operator may not be fully installed"
            OPERATOR_INSTALLED=false
        fi
    else
        log "No operator CSV found, operator is not installed"
        OPERATOR_INSTALLED=false
    fi
    
    # Only check for SecuredCluster if operator is actually installed
    if [ "$OPERATOR_INSTALLED" = "true" ]; then
        if $KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            # Check if it's being deleted
            DELETION_TIMESTAMP=$($KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")
            if [ -n "$DELETION_TIMESTAMP" ] && [ "$DELETION_TIMESTAMP" != "" ]; then
                log "SecuredCluster exists but is being deleted, will recreate"
                SECURED_CLUSTER_EXISTS=false
            else
                SECURED_CLUSTER_EXISTS=true
            fi
        fi
    fi
else
    log "SecuredCluster CRD not found, operator is not installed"
fi

# Proceed with operator installation if needed
if [ "$SECURED_CLUSTER_EXISTS" != "true" ] || [ "$OPERATOR_INSTALLED" != "true" ]; then
    # Ensure namespace exists in aws-us cluster
    log "Ensuring namespace '$RHACS_OPERATOR_NAMESPACE' exists in aws-us cluster..."
    if ! $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        $KUBECTL_CMD create namespace "$RHACS_OPERATOR_NAMESPACE" || error "Failed to create namespace"
        log "✓ Operator namespace created"
    else
        log "✓ Operator namespace exists"
    fi

    # Check if SecuredCluster CRD exists and operator is properly installed, install operator if needed
    log "Checking if SecuredCluster CRD is installed..."
    CRD_EXISTS=false
    if $KUBECTL_CMD get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
        CRD_EXISTS=true
        log "SecuredCluster CRD found"
    fi
    
    # Check if operator is actually installed (CSV exists and is Succeeded)
    NEED_OPERATOR_INSTALL=true
    if [ "$CRD_EXISTS" = "true" ]; then
        CSV_NAME=$($KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
        if [ -z "$CSV_NAME" ] || [ "$CSV_NAME" = "" ]; then
            CSV_NAME=$($KUBECTL_CMD get csv -n openshift-operators 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
        fi
        if [ -n "$CSV_NAME" ] && [ "$CSV_NAME" != "" ]; then
            CSV_PHASE=$($KUBECTL_CMD get csv "$CSV_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [ -z "$CSV_PHASE" ] || [ "$CSV_PHASE" = "" ]; then
                CSV_PHASE=$($KUBECTL_CMD get csv "$CSV_NAME" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            fi
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "Operator CSV is installed and in Succeeded phase"
                NEED_OPERATOR_INSTALL=false
            else
                log "Operator CSV exists but phase is '${CSV_PHASE:-unknown}', operator may need reinstallation"
            fi
        else
            log "CRD exists but no operator CSV found, operator needs to be installed"
        fi
    fi
    
    if [ "$NEED_OPERATOR_INSTALL" = "true" ]; then
        if [ "$CRD_EXISTS" = "false" ]; then
            log "SecuredCluster CRD not found. Installing RHACS operator..."
        else
            log "SecuredCluster CRD exists but operator is not properly installed. Installing RHACS operator..."
        fi
        
        # Verify namespace exists
        if ! $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            error "Namespace '$RHACS_OPERATOR_NAMESPACE' does not exist. Cannot install operator."
        fi
        
        # Create OperatorGroup if it doesn't exist
        if ! $KUBECTL_CMD get operatorgroup rhacs-operator-group -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            log "Creating OperatorGroup..."
            if ! cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhacs-operator-group
  namespace: $RHACS_OPERATOR_NAMESPACE
spec: {}
EOF
            then
                error "Failed to create OperatorGroup"
            fi
            log "✓ OperatorGroup created (cluster-wide)"
        else
            log "✓ OperatorGroup already exists"
        fi
        
        # Create Subscription for RHACS operator
        log "Creating RHACS operator subscription..."
        SUBSCRIPTION_YAML=$(cat <<EOF
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
)
        if ! echo "$SUBSCRIPTION_YAML" | $KUBECTL_CMD apply -f -; then
            error "Failed to create RHACS operator subscription"
        fi
        
        # Verify subscription was created with explicit API group
        log "Verifying subscription was created..."
        sleep 3
        if ! $KUBECTL_CMD get subscription.operators.coreos.com rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            warning "Subscription not found with explicit API group, checking without..."
            if ! $KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                error "Subscription 'rhacs-operator' not found in namespace '$RHACS_OPERATOR_NAMESPACE' after creation. Check operator installation manually."
            fi
        fi
        log "✓ Operator subscription created and verified"
        
        # Check subscription status and InstallPlan
        log "Checking subscription status..."
        sleep 5  # Give subscription time to create InstallPlan
        SUBSCRIPTION_STATUS=$($KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
        INSTALL_PLAN=$($KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || echo "")
        log "Subscription state: ${SUBSCRIPTION_STATUS:-unknown}"
        if [ -n "$INSTALL_PLAN" ] && [ "$INSTALL_PLAN" != "null" ] && [ "$INSTALL_PLAN" != "" ]; then
            log "InstallPlan: $INSTALL_PLAN"
            INSTALL_PLAN_PHASE=$($KUBECTL_CMD get installplan "$INSTALL_PLAN" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [ -n "$INSTALL_PLAN_PHASE" ]; then
                log "InstallPlan phase: $INSTALL_PLAN_PHASE"
            fi
        else
            log "Waiting for InstallPlan to be created..."
        fi
        
        # Check if CSV already exists before waiting
        CSV_NAME=$($KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
        if [ -z "$CSV_NAME" ] || [ "$CSV_NAME" = "null" ] || [ "$CSV_NAME" = "" ]; then
            CSV_NAME=$($KUBECTL_CMD get csv -n openshift-operators 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
        fi
        
        # Wait for CSV to be installed first (if not already found)
        if [ -n "$CSV_NAME" ] && [ "$CSV_NAME" != "null" ] && [ "$CSV_NAME" != "" ]; then
            log "✓ Operator CSV already exists: $CSV_NAME"
        else
            log "Waiting for RHACS operator CSV to be installed..."
            csv_wait_count=0
            csv_max_wait=300
            CSV_NAME=""
            while [ -z "$CSV_NAME" ] || [ "$CSV_NAME" = "null" ] || [ "$CSV_NAME" = "" ]; do
            if [ $csv_wait_count -ge $csv_max_wait ]; then
                warning "Timeout waiting for operator CSV. Checking subscription and InstallPlan status..."
                $KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" -o yaml 2>/dev/null | grep -A 15 "status:" || true
                INSTALL_PLAN=$($KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || echo "")
                if [ -n "$INSTALL_PLAN" ] && [ "$INSTALL_PLAN" != "null" ]; then
                    log "Checking InstallPlan $INSTALL_PLAN..."
                    $KUBECTL_CMD get installplan "$INSTALL_PLAN" -n "$RHACS_OPERATOR_NAMESPACE" -o yaml 2>/dev/null | grep -A 20 "status:" || true
                fi
                log "Checking for CSV in rhacs-operator namespace..."
                $KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null || true
                log "Checking for CSV in openshift-operators namespace..."
                $KUBECTL_CMD get csv -n openshift-operators 2>/dev/null | grep rhacs || true
                error "Operator CSV installation timeout. Please check operator installation manually."
            fi
            # Check both rhacs-operator and openshift-operators namespaces for CSV
            # Use simpler approach: get all CSVs and filter for rhacs-operator (skip header)
            CSV_NAME=$($KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
            if [ -z "$CSV_NAME" ] || [ "$CSV_NAME" = "null" ] || [ "$CSV_NAME" = "" ]; then
                CSV_NAME=$($KUBECTL_CMD get csv -n openshift-operators 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
            fi
            sleep 2
            csv_wait_count=$((csv_wait_count + 1))
            if [ $((csv_wait_count % 20)) -eq 0 ]; then
                log "  Still waiting for CSV... ($csv_wait_count/${csv_max_wait}s)"
                # Debug: show what CSVs we found
                if [ $csv_wait_count -eq 20 ]; then
                    log "  Available CSVs in $RHACS_OPERATOR_NAMESPACE:"
                    $KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null | head -5 || true
                fi
                # Check InstallPlan status periodically
                INSTALL_PLAN=$($KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || echo "")
                if [ -n "$INSTALL_PLAN" ] && [ "$INSTALL_PLAN" != "null" ]; then
                    INSTALL_PLAN_PHASE=$($KUBECTL_CMD get installplan "$INSTALL_PLAN" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                    if [ -n "$INSTALL_PLAN_PHASE" ]; then
                        log "  InstallPlan phase: $INSTALL_PLAN_PHASE"
                    fi
                fi
            fi
            done
            log "✓ Operator CSV found: $CSV_NAME"
        fi
        
        # Determine which namespace the CSV is in
        CSV_NAMESPACE="$RHACS_OPERATOR_NAMESPACE"
        if ! $KUBECTL_CMD get csv "$CSV_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            CSV_NAMESPACE="openshift-operators"
        fi
        log "CSV is in namespace: $CSV_NAMESPACE"
        
        # Wait for CSV to be in Succeeded phase
        log "Waiting for operator CSV to be ready..."
        csv_ready_wait_count=0
        csv_ready_max_wait=600  # Increased to 10 minutes for single-node clusters
        while true; do
            CSV_PHASE=$($KUBECTL_CMD get csv "$CSV_NAME" -n "$CSV_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                break
            fi
            
            # Check for stuck installation states
            CSV_MESSAGE=$($KUBECTL_CMD get csv "$CSV_NAME" -n "$CSV_NAMESPACE" -o jsonpath='{.status.message}' 2>/dev/null || echo "")
            if [ -n "$CSV_MESSAGE" ] && [[ "$CSV_MESSAGE" == *"not available"* ]] || [[ "$CSV_MESSAGE" == *"minimum availability"* ]]; then
                if [ $((csv_ready_wait_count % 60)) -eq 0 ]; then
                    warning "Operator installation appears stuck: $CSV_MESSAGE"
                    log "Checking operator deployment status..."
                    $KUBECTL_CMD get deployment rhacs-operator-controller-manager -n "$CSV_NAMESPACE" -o yaml 2>/dev/null | grep -A 10 "status:" || true
                    log "Checking operator pods..."
                    $KUBECTL_CMD get pods -n "$CSV_NAMESPACE" | grep rhacs-operator || true
                fi
            fi
            
            if [ $csv_ready_wait_count -ge $csv_ready_max_wait ]; then
                warning "Timeout waiting for CSV to be ready. Current phase: ${CSV_PHASE:-unknown}"
                if [ -n "$CSV_MESSAGE" ]; then
                    warning "CSV message: $CSV_MESSAGE"
                fi
                log "CSV status details:"
                $KUBECTL_CMD get csv "$CSV_NAME" -n "$CSV_NAMESPACE" -o yaml 2>/dev/null | grep -A 30 "status:" || true
                log "Operator deployment status:"
                $KUBECTL_CMD get deployment rhacs-operator-controller-manager -n "$CSV_NAMESPACE" 2>/dev/null || log "Deployment not found"
                log "Operator pods:"
                $KUBECTL_CMD get pods -n "$CSV_NAMESPACE" | grep rhacs-operator || log "No operator pods found"
                warning "Operator CSV installation timeout. The operator may need manual intervention."
                warning "You may need to check resource constraints, node availability, or operator subscription issues."
                error "Please check operator installation manually and retry."
            fi
            sleep 2
            csv_ready_wait_count=$((csv_ready_wait_count + 1))
            if [ $((csv_ready_wait_count % 30)) -eq 0 ]; then
                log "  Still waiting for CSV to be ready... ($csv_ready_wait_count/${csv_ready_max_wait}s) - Phase: ${CSV_PHASE:-pending}"
                if [ -n "$CSV_MESSAGE" ]; then
                    log "  Status: $CSV_MESSAGE"
                fi
            fi
        done
        log "✓ Operator CSV is ready"
        
        # Wait for CRD to be available (only if it doesn't already exist)
        if ! $KUBECTL_CMD get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
            log "Waiting for SecuredCluster CRD to be installed..."
            wait_count=0
            max_wait=120
            while ! $KUBECTL_CMD get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; do
                if [ $wait_count -ge $max_wait ]; then
                    warning "Timeout waiting for SecuredCluster CRD to be installed"
                    warning "Checking operator installation status..."
                    CSV_NAMESPACE="$RHACS_OPERATOR_NAMESPACE"
                    if ! $KUBECTL_CMD get csv "$CSV_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                        CSV_NAMESPACE="openshift-operators"
                    fi
                    $KUBECTL_CMD get csv "$CSV_NAME" -n "$CSV_NAMESPACE" -o yaml 2>/dev/null | grep -A 20 "status:" || true
                    error "SecuredCluster CRD installation timeout. Please check operator installation manually."
                fi
                sleep 2
                wait_count=$((wait_count + 1))
                if [ $((wait_count % 20)) -eq 0 ]; then
                    log "  Still waiting for CRD... ($wait_count/${max_wait}s)"
                fi
            done
            log "✓ SecuredCluster CRD installed"
        else
            log "✓ SecuredCluster CRD already exists"
        fi
    else
        log "✓ Operator is already installed, skipping operator installation"
    fi
fi

# Always ensure namespace exists and apply SecuredCluster configuration
# Ensure namespace exists in aws-us cluster
log "Ensuring namespace '$RHACS_OPERATOR_NAMESPACE' exists in aws-us cluster..."
if ! $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    $KUBECTL_CMD create namespace "$RHACS_OPERATOR_NAMESPACE" || error "Failed to create namespace"
    log "✓ Operator namespace created"
else
    log "✓ Operator namespace exists"
fi

# Verify operator is installed before proceeding
if ! $KUBECTL_CMD get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
    error "SecuredCluster CRD not found. Operator must be installed first. Please run the script again to install the operator."
fi

# Apply init bundle secrets to aws-us cluster
# CRITICAL: Apply init bundle BEFORE creating SecuredCluster to avoid race conditions
if [ -f "$INIT_BUNDLE_FILE" ]; then
    log "Applying init bundle secrets to aws-us cluster from: $INIT_BUNDLE_FILE"
    log "NOTE: Init bundle must be applied BEFORE SecuredCluster creation to avoid certificate race conditions"
    
    # Check for existing secrets and delete them if they exist (to avoid stale data from previous installs)
    log "Checking for existing init bundle secrets from previous installations..."
    for secret in sensor-tls admission-control-tls collector-tls; do
        if $KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            log "  Found existing secret $secret, deleting to ensure fresh init bundle..."
            $KUBECTL_CMD delete secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true || true
            sleep 1
        fi
    done
    
    # Apply init bundle
    if ! $KUBECTL_CMD apply -f "$INIT_BUNDLE_FILE" -n "$RHACS_OPERATOR_NAMESPACE"; then
        error "Failed to apply init bundle secrets. Check the init bundle file: $INIT_BUNDLE_FILE"
    fi
    log "✓ Init bundle secrets applied"
    
    # Wait and verify the secrets were fully created (not just applied)
    log "Waiting for init bundle secrets to be fully created and verified..."
    REQUIRED_SECRETS=("sensor-tls" "admission-control-tls" "collector-tls")
    SECRET_WAIT_COUNT=0
    SECRET_MAX_WAIT=60
    ALL_SECRETS_READY=false
    
    while [ $SECRET_WAIT_COUNT -lt $SECRET_MAX_WAIT ]; do
        MISSING_SECRETS=()
        EMPTY_SECRETS=()
        
        for secret in "${REQUIRED_SECRETS[@]}"; do
            if ! $KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                MISSING_SECRETS+=("$secret")
            else
                # Verify secret has data
                SECRET_DATA=$($KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data}' 2>/dev/null || echo "")
                if [ -z "$SECRET_DATA" ] || [ "$SECRET_DATA" = "{}" ]; then
                    EMPTY_SECRETS+=("$secret")
                fi
            fi
        done
        
        if [ ${#MISSING_SECRETS[@]} -eq 0 ] && [ ${#EMPTY_SECRETS[@]} -eq 0 ]; then
            ALL_SECRETS_READY=true
            break
        fi
        
        sleep 2
        SECRET_WAIT_COUNT=$((SECRET_WAIT_COUNT + 2))
        
        if [ $((SECRET_WAIT_COUNT % 10)) -eq 0 ]; then
            if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
                log "  Still waiting for secrets: ${MISSING_SECRETS[*]}"
            fi
            if [ ${#EMPTY_SECRETS[@]} -gt 0 ]; then
                log "  Secrets exist but empty: ${EMPTY_SECRETS[*]}"
            fi
        fi
    done
    
    if [ "$ALL_SECRETS_READY" = "false" ]; then
        if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
            error "Timeout waiting for init bundle secrets to be created: ${MISSING_SECRETS[*]}. Check the init bundle file: $INIT_BUNDLE_FILE"
        fi
        if [ ${#EMPTY_SECRETS[@]} -gt 0 ]; then
            error "Init bundle secrets exist but are empty: ${EMPTY_SECRETS[*]}. The init bundle may be corrupted. Regenerate it."
        fi
    fi
    
    log "✓ All required secrets verified and ready: ${REQUIRED_SECRETS[*]}"
    log "  All secrets contain certificate data and are ready for use"
    
    # Additional verification: ensure secrets are in the correct namespace
    log "Verifying secrets are in the correct namespace: $RHACS_OPERATOR_NAMESPACE"
    for secret in "${REQUIRED_SECRETS[@]}"; do
        SECRET_NAMESPACE=$($KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.metadata.namespace}' 2>/dev/null || echo "")
        if [ "$SECRET_NAMESPACE" != "$RHACS_OPERATOR_NAMESPACE" ]; then
            warning "Secret $secret is in namespace '$SECRET_NAMESPACE' but should be in '$RHACS_OPERATOR_NAMESPACE'"
        fi
    done
    
    log "Init bundle saved at: $INIT_BUNDLE_FILE (kept for reference)"
else
    # Try to find any existing init bundle file for this cluster
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    INIT_BUNDLES_DIR="${SCRIPT_DIR}/init-bundles"
    EXISTING_BUNDLE=$(find "$INIT_BUNDLES_DIR" -name "${CLUSTER_NAME}-init-bundle*.yaml" 2>/dev/null | head -1)
    if [ -n "$EXISTING_BUNDLE" ] && [ -f "$EXISTING_BUNDLE" ]; then
        log "Found existing init bundle file: $EXISTING_BUNDLE"
        log "Applying init bundle secrets to aws-us cluster..."
        
        # Clean up existing secrets first (same as above)
        log "Cleaning up any existing init bundle secrets..."
        for secret in sensor-tls admission-control-tls collector-tls; do
            if $KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                log "  Deleting existing secret $secret..."
                $KUBECTL_CMD delete secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true || true
                sleep 1
            fi
        done
        
        if ! $KUBECTL_CMD apply -f "$EXISTING_BUNDLE" -n "$RHACS_OPERATOR_NAMESPACE"; then
            error "Failed to apply existing init bundle secrets. Regenerate the init bundle: $EXISTING_BUNDLE"
        fi
        
        # Use same robust verification as above
        log "Waiting for init bundle secrets to be fully created..."
        REQUIRED_SECRETS=("sensor-tls" "admission-control-tls" "collector-tls")
        SECRET_WAIT_COUNT=0
        SECRET_MAX_WAIT=60
        ALL_SECRETS_READY=false
        
        while [ $SECRET_WAIT_COUNT -lt $SECRET_MAX_WAIT ]; do
            MISSING_SECRETS=()
            EMPTY_SECRETS=()
            
            for secret in "${REQUIRED_SECRETS[@]}"; do
                if ! $KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                    MISSING_SECRETS+=("$secret")
                else
                    SECRET_DATA=$($KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data}' 2>/dev/null || echo "")
                    if [ -z "$SECRET_DATA" ] || [ "$SECRET_DATA" = "{}" ]; then
                        EMPTY_SECRETS+=("$secret")
                    fi
                fi
            done
            
            if [ ${#MISSING_SECRETS[@]} -eq 0 ] && [ ${#EMPTY_SECRETS[@]} -eq 0 ]; then
                ALL_SECRETS_READY=true
                break
            fi
            
            sleep 2
            SECRET_WAIT_COUNT=$((SECRET_WAIT_COUNT + 2))
        done
        
        if [ "$ALL_SECRETS_READY" = "false" ]; then
            if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
                error "Timeout waiting for init bundle secrets: ${MISSING_SECRETS[*]}. Regenerate the init bundle."
            fi
            if [ ${#EMPTY_SECRETS[@]} -gt 0 ]; then
                error "Init bundle secrets are empty: ${EMPTY_SECRETS[*]}. The init bundle may be corrupted. Regenerate it."
            fi
        fi
        
        log "✓ All required secrets verified and ready: ${REQUIRED_SECRETS[*]}"
    else
        error "Init bundle file not found. Cannot proceed without init bundle secrets."
        error "Expected location: $INIT_BUNDLE_FILE"
        error "Please ensure the init bundle is generated before creating the SecuredCluster."
    fi
fi

# Create or update SecuredCluster resource in aws-us cluster (optimized for single-node)
if [ "$SECURED_CLUSTER_EXISTS" = "true" ]; then
    log "Updating existing SecuredCluster resource for single-node optimization..."
else
    log "Creating SecuredCluster resource in aws-us cluster (optimized for single-node)..."
fi

# Construct Central endpoint for SecuredCluster - must be in host:port format (no protocol, no path)
# ROX_ENDPOINT was set earlier when we were on local-cluster context
# Ensure it's properly normalized for the SecuredCluster centralEndpoint field
if [ -z "${ROX_ENDPOINT_NORMALIZED:-}" ]; then
    # Normalize ROX_ENDPOINT: ensure it's host:port format
    CENTRAL_ENDPOINT="${ROX_ENDPOINT}"
    # Strip any remaining path (should already be done, but be safe)
    CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT%%/*}"
    CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT%/}"
    # Ensure port is present
    if [[ "$CENTRAL_ENDPOINT" != *:* ]]; then
        CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT}:443"
    fi
else
    CENTRAL_ENDPOINT="${ROX_ENDPOINT_NORMALIZED}"
fi

# Final validation: ensure endpoint is in correct format for SecuredCluster (host:port only)
if [[ "$CENTRAL_ENDPOINT" == *"://"* ]]; then
    warning "Central endpoint contains protocol, stripping: $CENTRAL_ENDPOINT"
    CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT#*://}"
    CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT%%/*}"
fi
if [[ "$CENTRAL_ENDPOINT" == *"/"* ]]; then
    warning "Central endpoint contains path, stripping: $CENTRAL_ENDPOINT"
    CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT%%/*}"
fi
if [[ "$CENTRAL_ENDPOINT" != *:* ]]; then
    CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT}:443"
fi

log "Configuring SecuredCluster centralEndpoint: $CENTRAL_ENDPOINT"
log "  (This is the API endpoint the sensor will use to connect to Central)"

cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: platform.stackrox.io/v1alpha1
kind: SecuredCluster
metadata:
  name: $SECURED_CLUSTER_NAME
  namespace: $RHACS_OPERATOR_NAMESPACE
spec:
  clusterName: "$CLUSTER_NAME"
  centralEndpoint: "$CENTRAL_ENDPOINT"
  auditLogs:
    collection: Auto
  admissionControl:
    enforcement: Enabled
    bypass: BreakGlassAnnotation
    failurePolicy: Ignore
    dynamic:
      disableBypass: false
    replicas: 1
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        operator: Exists
        effect: NoSchedule
  scanner:
    scannerComponent: Disabled
  scannerV4:
    scannerComponent: Disabled
  collector:
    collectionMethod: KernelModule
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        operator: Exists
        effect: NoSchedule
  sensor:
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        operator: Exists
        effect: NoSchedule
  processBaselines:
    autoLock: Enabled
EOF
    
if [ "$SECURED_CLUSTER_EXISTS" = "true" ]; then
    log "✓ SecuredCluster resource updated"
else
    log "✓ SecuredCluster resource created"
fi

# Handle operator reconciliation glitches after install/delete cycles
log "Checking for operator reconciliation issues..."
# Check if SecuredCluster has deletion timestamp (stuck in deletion)
DELETION_TIMESTAMP=$($KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")
if [ -n "$DELETION_TIMESTAMP" ] && [ "$DELETION_TIMESTAMP" != "" ]; then
    warning "SecuredCluster has deletion timestamp - it may be stuck from a previous install/delete cycle"
    warning "Removing finalizers to allow cleanup..."
    $KUBECTL_CMD patch securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    sleep 5
    
    # Wait for it to be fully deleted, then it will be recreated by the apply above
    DELETE_WAIT=0
    while $KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; do
        if [ $DELETE_WAIT -ge 30 ]; then
            warning "SecuredCluster still exists after removing finalizers. Forcing deletion..."
            $KUBECTL_CMD delete securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" --force --grace-period=0 2>/dev/null || true
            break
        fi
        sleep 2
        DELETE_WAIT=$((DELETE_WAIT + 2))
    done
    
    log "SecuredCluster cleaned up, will be recreated by operator"
    sleep 3
fi

# Check for stuck pods from previous installations
log "Checking for stuck pods from previous installations..."
STUCK_PODS=$($KUBECTL_CMD get pods -n "$RHACS_OPERATOR_NAMESPACE" --field-selector=status.phase!=Running,status.phase!=Succeeded -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -n "$STUCK_PODS" ]; then
    for pod in $STUCK_PODS; do
        POD_AGE=$($KUBECTL_CMD get pod "$pod" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "")
        # Only clean up pods older than 5 minutes (to avoid deleting newly created ones)
        if [ -n "$POD_AGE" ]; then
            log "  Found potentially stuck pod: $pod (created: $POD_AGE)"
        fi
    done
fi

# Wait for operator to start reconciling
log "Waiting for operator to reconcile SecuredCluster resource..."
sleep 5

# Wait for sensor deployment to be created and ready (indicates connection to Central)
log "Waiting for sensor to be created and connect to Central..."
SENSOR_WAIT_COUNT=0
SENSOR_MAX_WAIT=300
SENSOR_READY=false

while [ $SENSOR_WAIT_COUNT -lt $SENSOR_MAX_WAIT ]; do
    # Check if sensor deployment exists
    if $KUBECTL_CMD get deployment sensor -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        # Check if sensor pod is running and ready
        SENSOR_READY_REPLICAS=$($KUBECTL_CMD get deployment sensor -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        SENSOR_REPLICAS=$($KUBECTL_CMD get deployment sensor -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        
        if [ "$SENSOR_REPLICAS" != "0" ] && [ "$SENSOR_READY_REPLICAS" = "$SENSOR_REPLICAS" ]; then
            # Check if sensor pod has connected to Central (no init-tls-certs errors)
            SENSOR_POD=$($KUBECTL_CMD get pods -n "$RHACS_OPERATOR_NAMESPACE" -l app=sensor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$SENSOR_POD" ] && [ "$SENSOR_POD" != "" ]; then
                # Check pod status - if it's Running, sensor likely connected
                POD_PHASE=$($KUBECTL_CMD get pod "$SENSOR_POD" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$POD_PHASE" = "Running" ]; then
                    # Check for init-tls-certs container errors
                    INIT_TLS_ERRORS=$($KUBECTL_CMD logs "$SENSOR_POD" -n "$RHACS_OPERATOR_NAMESPACE" -c init-tls-certs 2>&1 | grep -i "error\|failed\|timeout" | wc -l || echo "0")
                    if [ "$INIT_TLS_ERRORS" = "0" ] || [ -z "$INIT_TLS_ERRORS" ]; then
                        SENSOR_READY=true
                        break
                    fi
                fi
            fi
        fi
    fi
    
    sleep 5
    SENSOR_WAIT_COUNT=$((SENSOR_WAIT_COUNT + 5))
    
    if [ $((SENSOR_WAIT_COUNT % 30)) -eq 0 ]; then
        log "  Still waiting for sensor to connect to Central... (${SENSOR_WAIT_COUNT}/${SENSOR_MAX_WAIT}s)"
        if $KUBECTL_CMD get deployment sensor -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            SENSOR_STATUS=$($KUBECTL_CMD get deployment sensor -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
            log "  Sensor deployment status: ${SENSOR_STATUS:-unknown}"
        fi
    fi
done

if [ "$SENSOR_READY" = "true" ]; then
    log "✓ Sensor is running and connected to Central"
else
    warning "Sensor may not be fully ready yet. This is normal for SNO clusters - sensor will continue connecting in the background."
    warning "Monitor sensor pod logs if connection issues persist: oc logs -n $RHACS_OPERATOR_NAMESPACE -l app=sensor"
fi

# Verify Scanner V4 is disabled (as configured for SNO)
log "Verifying Scanner V4 configuration..."
SCANNER_V4_COMPONENT=$($KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.scannerV4.scannerComponent}' 2>/dev/null || echo "")
if [ "$SCANNER_V4_COMPONENT" = "Disabled" ]; then
    log "✓ Scanner V4 is disabled (appropriate for single-node cluster)"
else
    warning "Scanner V4 component: ${SCANNER_V4_COMPONENT:-unknown} (expected: Disabled)"
fi

log "Secured Cluster Services deployment initiated for aws-us cluster"
log "The SecuredCluster will connect to Central running on local-cluster"
log ""
log "IMPORTANT NOTES:"
log "  - Init bundle secrets are applied in namespace: $RHACS_OPERATOR_NAMESPACE"
log "  - Central endpoint configured: $CENTRAL_ENDPOINT"
log "  - Scanner V4 is disabled (to reduce resource usage on single-node)"
log "  - If pods fail to start, check init bundle secrets and sensor connection"
log "  - Monitor pod logs: oc logs -n $RHACS_OPERATOR_NAMESPACE <pod-name> -c init-tls-certs"

log "ACS setup complete"
