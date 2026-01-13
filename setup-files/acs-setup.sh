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
