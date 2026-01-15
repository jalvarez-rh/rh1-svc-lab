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
    "01-rhacs-delete.sh"
    "02-install-cert-manager.sh"
    "03-setup-rhacs-route-tls.sh"
    "04-rhacs-subscription-install.sh"
    "05-central-install.sh"
    "06-scs-setup.sh"
    "07-compliance-operator-install.sh"
    "08-deploy-applications.sh"
    "09-setup-co-scan-schedule.sh"
    "10-trigger-compliance-scan.sh"
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

for script in "${SCRIPTS[@]}"; do
    CURRENT=$((CURRENT + 1))
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
    exit 0
else
    error "✗ Failed scripts: ${FAILED_SCRIPTS[*]}"
fi
