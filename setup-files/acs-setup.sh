#!/bin/bash
# ACS Setup Script
# Downloads and sets up roxctl CLI and performs ACS configuration tasks

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

# Download and setup roxctl CLI version 4.9
log "Downloading roxctl CLI version 4.9..."
ROXCTL_VERSION="4.9.0"
ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/${ROXCTL_VERSION}/bin/${ROXCTL_ARCH}/roxctl"
ROXCTL_TMP="/tmp/roxctl"

# Check if roxctl already exists and is the correct version
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

# Generate API token and save to ~/.bashrc
log "Generating RHACS API token..."

# Check if required environment variables are set
if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
    warning "ROX_CENTRAL_ADDRESS not set. Loading from ~/.bashrc if available..."
    if [ -f ~/.bashrc ]; then
        set +u
        source ~/.bashrc
        set -u
    fi
fi

if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
    warning "ROX_CENTRAL_ADDRESS not found. Skipping API token generation."
    warning "Please set ROX_CENTRAL_ADDRESS, ACS_PORTAL_USERNAME, and ACS_PORTAL_PASSWORD in ~/.bashrc first."
else
    # Check if token already exists in bashrc
    if grep -q "ROX_API_TOKEN" ~/.bashrc 2>/dev/null; then
        log "ROX_API_TOKEN already exists in ~/.bashrc, skipping token generation"
    else
        # Ensure credentials are available
        if [ -z "${ACS_PORTAL_USERNAME:-}" ] || [ -z "${ACS_PORTAL_PASSWORD:-}" ]; then
            warning "ACS_PORTAL_USERNAME or ACS_PORTAL_PASSWORD not set. Loading from ~/.bashrc if available..."
            if [ -f ~/.bashrc ]; then
                set +u
                source ~/.bashrc
                set -u
            fi
        fi

        if [ -z "${ACS_PORTAL_USERNAME:-}" ] || [ -z "${ACS_PORTAL_PASSWORD:-}" ]; then
            warning "ACS credentials not found. Skipping API token generation."
            warning "Please set ACS_PORTAL_USERNAME and ACS_PORTAL_PASSWORD in ~/.bashrc first."
        else
            # Generate token using roxctl
            log "Generating API token with roxctl..."
            set +e
            TOKEN_OUTPUT=$(roxctl central api-token generate \
                --insecure-skip-tls-verify \
                -e "$ROX_CENTRAL_ADDRESS" \
                -u "$ACS_PORTAL_USERNAME" \
                -p "$ACS_PORTAL_PASSWORD" \
                --name "acs-setup-script-token" \
                --role Admin 2>&1)
            TOKEN_EXIT_CODE=$?
            set -e

            if [ $TOKEN_EXIT_CODE -eq 0 ]; then
                # Extract token from output (roxctl outputs the token directly or in JSON format)
                ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
                
                # Try JSON parsing if available
                if command -v jq >/dev/null 2>&1 && echo "$TOKEN_OUTPUT" | jq . >/dev/null 2>&1; then
                    ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | jq -r '.token // .data.token // empty' 2>/dev/null || echo "$ROX_API_TOKEN")
                fi

                if [ -n "$ROX_API_TOKEN" ] && [ ${#ROX_API_TOKEN} -ge 20 ]; then
                    # Append to ~/.bashrc
                    if ! grep -q "ROX_API_TOKEN" ~/.bashrc 2>/dev/null; then
                        echo "" >> ~/.bashrc
                        echo "# RHACS API Token (generated by acs-setup.sh)" >> ~/.bashrc
                        echo "export ROX_API_TOKEN=\"$ROX_API_TOKEN\"" >> ~/.bashrc
                        log "✓ API token generated and saved to ~/.bashrc"
                    else
                        log "✓ API token generated (already exists in ~/.bashrc)"
                    fi
                else
                    warning "Failed to extract valid API token from roxctl output"
                    warning "Token output: ${TOKEN_OUTPUT:0:200}"
                fi
            else
                warning "Failed to generate API token. roxctl exit code: $TOKEN_EXIT_CODE"
                warning "Output: ${TOKEN_OUTPUT:0:300}"
            fi
        fi
    fi
fi

# Setup kubectl contexts for multi-cluster management
log "Configuring kubectl contexts..."

# Check if oc/kubectl is available
if ! command -v oc >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
    warning "oc or kubectl not found. Skipping context setup."
    exit 0
fi

# Use oc if available, otherwise kubectl
KUBECTL_CMD="oc"
if ! command -v oc >/dev/null 2>&1; then
    KUBECTL_CMD="kubectl"
fi

# Setup AWS cluster context (aws-us)
if [ -n "${AWS_OPENSHIFT_API_URL:-}" ] && [ -n "${AWS_OPENSHIFT_KUBEADMIN_PASSWORD:-}" ]; then
    log "Setting up aws-us context..."
    $KUBECTL_CMD login -u kubeadmin -p "$AWS_OPENSHIFT_KUBEADMIN_PASSWORD" "$AWS_OPENSHIFT_API_URL" --insecure-skip-tls-verify >/dev/null 2>&1 || warning "Failed to login to AWS cluster"
    CURRENT_CTX=$($KUBECTL_CMD config current-context 2>/dev/null || echo "")
    if [ -n "$CURRENT_CTX" ]; then
        $KUBECTL_CMD config rename-context "$CURRENT_CTX" aws-us 2>/dev/null || warning "Failed to rename context to aws-us"
        log "✓ aws-us context configured"
    fi
else
    warning "AWS cluster credentials not found in environment. Set AWS_OPENSHIFT_API_URL and AWS_OPENSHIFT_KUBEADMIN_PASSWORD to configure aws-us context."
fi

# Setup local cluster context (local-cluster)
# First check if 'admin' context exists and rename it
if $KUBECTL_CMD config get-contexts admin >/dev/null 2>&1; then
    log "Renaming existing 'admin' context to 'local-cluster'..."
    $KUBECTL_CMD config rename-context admin local-cluster 2>/dev/null && log "✓ local-cluster context configured (renamed from admin)" || warning "Failed to rename admin context to local-cluster"
elif [ -n "${OPENSHIFT_CLUSTER_CONSOLE_URL:-}" ] && [ -n "${OPENSHIFT_CLUSTER_ADMIN_USERNAME:-}" ] && [ -n "${OPENSHIFT_CLUSTER_ADMIN_PASSWORD:-}" ]; then
    log "Setting up local-cluster context..."
    $KUBECTL_CMD login -u "$OPENSHIFT_CLUSTER_ADMIN_USERNAME" -p "$OPENSHIFT_CLUSTER_ADMIN_PASSWORD" "$OPENSHIFT_CLUSTER_CONSOLE_URL" --insecure-skip-tls-verify >/dev/null 2>&1 || warning "Failed to login to local cluster"
    CURRENT_CTX=$($KUBECTL_CMD config current-context 2>/dev/null || echo "")
    if [ -n "$CURRENT_CTX" ] && [ "$CURRENT_CTX" != "aws-us" ]; then
        $KUBECTL_CMD config rename-context "$CURRENT_CTX" local-cluster 2>/dev/null || warning "Failed to rename context to local-cluster"
        log "✓ local-cluster context configured"
    fi
else
    warning "Local cluster credentials not found in environment and 'admin' context doesn't exist. Set OPENSHIFT_CLUSTER_CONSOLE_URL, OPENSHIFT_CLUSTER_ADMIN_USERNAME, and OPENSHIFT_CLUSTER_ADMIN_PASSWORD to configure local-cluster context."
fi

# Display configured contexts
log "Configured kubectl contexts:"
$KUBECTL_CMD config get-contexts 2>/dev/null || warning "Could not list contexts"

log "Kubectl context setup complete"
