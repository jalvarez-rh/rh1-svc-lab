#!/bin/bash
# Master script to execute all setup scripts in order
# This script runs all numbered setup scripts sequentially

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[SETUP-MASTER]${NC} $1"
}

error() {
    echo -e "${RED}[SETUP-MASTER] ERROR:${NC} $1" >&2
    exit 1
}

warning() {
    echo -e "${YELLOW}[SETUP-MASTER] WARNING:${NC} $1"
}

# Array of scripts to execute in order
SCRIPTS=(
    "00-install-roxctl.sh"
    # "01-central-install.sh"
    "02-compliance-operator-install.sh"
    "03-deploy-applications.sh"
    "04-configure-rhacs-settings.sh"
    "05-setup-perses-monitoring.sh"
    # "06-scs-second-cluster.sh"
    # "07-compliance-operator-second-cluster.sh"
)

log "========================================================="
log "Starting master setup script"
log "========================================================="
log "Script directory: $SCRIPT_DIR"
log ""

# Check if all scripts exist
MISSING_SCRIPTS=()
for script in "${SCRIPTS[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$script" ]; then
        MISSING_SCRIPTS+=("$script")
    fi
done

if [ ${#MISSING_SCRIPTS[@]} -gt 0 ]; then
    error "The following required scripts are missing: ${MISSING_SCRIPTS[*]}"
fi

log "Found all ${#SCRIPTS[@]} required scripts"
log ""

# Execute each script in order
TOTAL=${#SCRIPTS[@]}
CURRENT=0
FAILED_SCRIPTS=()

for idx in "${!SCRIPTS[@]}"; do
    script="${SCRIPTS[$idx]}"
    CURRENT=$((idx + 1))
    
    log "========================================================="
    log "Executing script $CURRENT/$TOTAL: $script"
    log "========================================================="
    
    # Make sure script is executable
    chmod +x "$SCRIPT_DIR/$script"
    
    # Execute the script
    if bash "$SCRIPT_DIR/$script"; then
        log "✓ Successfully completed: $script"
    else
        EXIT_CODE=$?
        error "✗ Script failed: $script (exit code: $EXIT_CODE)"
        FAILED_SCRIPTS+=("$script")
    fi
    
    log ""
done

# Summary
log "========================================================="
log "Setup Summary"
log "========================================================="
log "Total scripts executed: $TOTAL"

if [ ${#FAILED_SCRIPTS[@]} -eq 0 ]; then
    log "✓ All scripts completed successfully!"
    log "========================================================="
    
    # Display RHACS URL and password if RHACS is installed
    log ""
    log "========================================================="
    log "RHACS Access Information"
    log "========================================================="
    
    RHACS_OPERATOR_NAMESPACE="rhacs-operator"
    
    # Get RHACS Central URL from route
    CENTRAL_ROUTE=$(oc get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$CENTRAL_ROUTE" ]; then
        # Check if route uses TLS
        CENTRAL_TLS=$(oc get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.tls}' 2>/dev/null || echo "")
        if [ -n "$CENTRAL_TLS" ] && [ "$CENTRAL_TLS" != "null" ]; then
            CENTRAL_URL="https://${CENTRAL_ROUTE}"
        else
            CENTRAL_URL="http://${CENTRAL_ROUTE}"
        fi
        log "RHACS Central URL: $CENTRAL_URL"
    else
        log "RHACS Central URL: Not found (route 'central' not found in namespace '$RHACS_OPERATOR_NAMESPACE')"
    fi
    
    # Get admin password from secret
    ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
    if [ -n "$ADMIN_PASSWORD_B64" ]; then
        ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || echo "")
        if [ -n "$ADMIN_PASSWORD" ]; then
            log "Admin Username: admin"
            log "Admin Password: $ADMIN_PASSWORD"
        else
            log "Admin Password: Could not decode password from secret"
        fi
    else
        log "Admin Password: Not found (secret 'central-htpasswd' not found in namespace '$RHACS_OPERATOR_NAMESPACE')"
    fi
    
    log "========================================================="
    log ""
    exit 0
else
    error "✗ Failed scripts: ${FAILED_SCRIPTS[*]}"
fi
