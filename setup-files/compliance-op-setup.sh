#!/bin/bash
# Compliance Scan Setup Script for RHACS
# Creates compliance scan configuration using existing API token

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[API-SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[API-SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[API-SETUP] ERROR:${NC} $1" >&2
    echo -e "${RED}[API-SETUP] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Load ROX_API_TOKEN and ROX_CENTRAL_ADDRESS from ~/.bashrc
if [ -f ~/.bashrc ]; then
    # Temporarily disable unbound variable check when sourcing bashrc
    set +u
    source ~/.bashrc
    set -u
fi

# Verify required variables are set
if [ -z "${ROX_API_TOKEN:-}" ]; then
    error "ROX_API_TOKEN not found in ~/.bashrc. Please ensure it is exported."
fi

if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
    error "ROX_CENTRAL_ADDRESS not found in ~/.bashrc. Please ensure it is exported."
fi

# Ensure ROX_CENTRAL_ADDRESS has https:// prefix
ROX_ENDPOINT="$ROX_CENTRAL_ADDRESS"
if [[ ! "$ROX_ENDPOINT" =~ ^https?:// ]]; then
    ROX_ENDPOINT="https://$ROX_ENDPOINT"
fi

log "Using ACS Central endpoint: $ROX_ENDPOINT"
log "API token loaded (length: ${#ROX_API_TOKEN} chars)"

# Ensure jq is installed
if ! command -v jq >/dev/null 2>&1; then
    log "Installing jq..."
    if command -v dnf >/dev/null 2>&1; then
        if ! sudo dnf install -y jq; then
            error "Failed to install jq using dnf. Check sudo permissions and package repository."
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        if ! sudo apt-get update && sudo apt-get install -y jq; then
            error "Failed to install jq using apt-get. Check sudo permissions and package repository."
        fi
    else
        error "jq not found and cannot be installed automatically. Please install jq manually."
    fi
    log "✓ jq installed successfully"
else
    log "✓ jq is already installed"
fi

# Fetch cluster ID from RHACS API
log "Fetching cluster ID from RHACS..."
set +e
CLUSTER_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 120 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v1/clusters" 2>&1)
CLUSTER_CURL_EXIT_CODE=$?
set -e

if [ $CLUSTER_CURL_EXIT_CODE -ne 0 ]; then
    error "Failed to fetch clusters (exit code: $CLUSTER_CURL_EXIT_CODE). Response: ${CLUSTER_RESPONSE:0:500}"
fi

if [ -z "$CLUSTER_RESPONSE" ]; then
    error "Empty response from cluster API"
fi

if ! echo "$CLUSTER_RESPONSE" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from cluster API. Response: ${CLUSTER_RESPONSE:0:300}"
fi

# Get all available cluster IDs
set +e
CLUSTER_IDS=$(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[]? | .id' 2>/dev/null | grep -v "^null$" | grep -v "^$" || echo "")
CLUSTER_NAMES=$(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[]? | "\(.name) (\(.id))"' 2>/dev/null | grep -v "^null" || echo "")
set -e

if [ -z "$CLUSTER_IDS" ]; then
    error "Failed to find any valid cluster IDs. Available clusters: $(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[]? | "\(.name): \(.id)"' 2>/dev/null | tr '\n' ' ' || echo "none")"
fi

# Count clusters and build JSON array
CLUSTER_COUNT=$(echo "$CLUSTER_IDS" | wc -l | tr -d '[:space:]')
log "✓ Found $CLUSTER_COUNT cluster(s):"
echo "$CLUSTER_NAMES" | while read -r line; do
    log "  - $line"
done

# Build JSON array of cluster IDs for the API payload
CLUSTER_IDS_JSON=$(echo "$CLUSTER_IDS" | jq -R . | jq -s .)

# Check for existing scan configuration and delete it
log "Checking for existing 'acs-catch-all' scan configuration..."
set +e
EXISTING_CONFIGS=$(curl -k -s --connect-timeout 15 --max-time 120 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
CONFIG_CURL_EXIT_CODE=$?
set -e

if [ $CONFIG_CURL_EXIT_CODE -eq 0 ] && echo "$EXISTING_CONFIGS" | jq . >/dev/null 2>&1; then
    EXISTING_SCAN=$(echo "$EXISTING_CONFIGS" | jq -r '.configurations[] | select(.scanName == "acs-catch-all") | .id' 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_SCAN" ] && [ "$EXISTING_SCAN" != "null" ]; then
        log "Found existing scan configuration 'acs-catch-all' (ID: $EXISTING_SCAN)"
        log "Deleting existing scan configuration..."
        
        set +e
        DELETE_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 120 -X DELETE \
            -H "Authorization: Bearer $ROX_API_TOKEN" \
            -H "Content-Type: application/json" \
            "$ROX_ENDPOINT/v2/compliance/scan/configurations/$EXISTING_SCAN" 2>&1)
        DELETE_EXIT_CODE=$?
        set -e
        
        if [ $DELETE_EXIT_CODE -eq 0 ]; then
            log "✓ Successfully deleted existing scan configuration"
            sleep 2
        else
            warning "Failed to delete existing scan configuration. Will attempt to create new one anyway."
        fi
    else
        log "No existing 'acs-catch-all' scan configuration found"
    fi
fi

# Create compliance scan configuration
log "Creating compliance scan configuration 'acs-catch-all' for $CLUSTER_COUNT cluster(s)..."
set +e
SCAN_CONFIG_RESPONSE=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 120 -X POST \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "{
    \"scanName\": \"acs-catch-all\",
    \"scanConfig\": {
        \"oneTimeScan\": false,
        \"profiles\": [
            \"ocp4-cis\",
            \"ocp4-cis-node\",
            \"ocp4-moderate\",
            \"ocp4-moderate-node\",
            \"ocp4-e8\",
            \"ocp4-high\",
            \"ocp4-high-node\",
            \"ocp4-nerc-cip\",
            \"ocp4-nerc-cip-node\",
            \"ocp4-pci-dss\",
            \"ocp4-pci-dss-node\",
            \"ocp4-stig\",
            \"ocp4-bsi\",
            \"ocp4-pci-dss-4-0\"
        ],
        \"scanSchedule\": {
            \"intervalType\": \"DAILY\",
            \"hour\": 12,
            \"minute\": 0
        },
        \"description\": \"Daily compliance scan for all profiles\"
    },
    \"clusters\": $CLUSTER_IDS_JSON
}" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
SCAN_CREATE_EXIT_CODE=$?
set -e

# Extract HTTP status code (last line) and response body (all but last line)
HTTP_CODE=$(echo "$SCAN_CONFIG_RESPONSE" | tail -1)
SCAN_CONFIG_BODY=$(echo "$SCAN_CONFIG_RESPONSE" | sed '$d')

if [ $SCAN_CREATE_EXIT_CODE -ne 0 ]; then
    error "Failed to create compliance scan configuration (exit code: $SCAN_CREATE_EXIT_CODE). HTTP Code: ${HTTP_CODE}. Response: ${SCAN_CONFIG_BODY:0:500}"
fi

if [ -z "$SCAN_CONFIG_BODY" ]; then
    error "Empty response from scan configuration creation API. HTTP Code: ${HTTP_CODE}"
fi

# Log the full response for debugging
log "API Response (HTTP ${HTTP_CODE}): ${SCAN_CONFIG_BODY:0:500}"

# Check HTTP status code
if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    error "Failed to create scan configuration. HTTP Status: ${HTTP_CODE}. Response: ${SCAN_CONFIG_BODY:0:500}"
fi

# Check for errors in response
if echo "$SCAN_CONFIG_BODY" | grep -qi "ProfileBundle.*still being processed"; then
    warning "Scan creation failed: ProfileBundle is still being processed"
    log "Please wait for ProfileBundles to be ready and retry."
    log "Check status: oc get profilebundle -n openshift-compliance"
    error "Cannot create scan: ProfileBundles are still being processed."
fi

if echo "$SCAN_CONFIG_BODY" | grep -qi "error\|failed\|invalid"; then
    warning "API returned an error response:"
    echo "$SCAN_CONFIG_BODY" | head -20
    error "Scan creation failed. See error above."
fi

if ! echo "$SCAN_CONFIG_BODY" | jq . >/dev/null 2>&1; then
    if echo "$SCAN_CONFIG_BODY" | grep -qi "ProfileBundle"; then
        warning "Scan creation failed with ProfileBundle-related error:"
        echo "$SCAN_CONFIG_BODY" | head -20
        error "ProfileBundle error detected. See above for details."
    else
        warning "Response is not valid JSON. Full response:"
        echo "$SCAN_CONFIG_BODY"
        error "Invalid JSON response from scan configuration creation API."
    fi
fi

log "✓ Compliance scan configuration created successfully"

# Get the scan configuration ID from response
SCAN_CONFIG_ID=$(echo "$SCAN_CONFIG_BODY" | jq -r '.id // .configuration.id // empty' 2>/dev/null)

# Verify the scan was actually created by checking the list
log "Verifying scan configuration was created..."
sleep 2
set +e
VERIFY_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 120 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
VERIFY_EXIT_CODE=$?
set -e

if [ $VERIFY_EXIT_CODE -eq 0 ] && echo "$VERIFY_RESPONSE" | jq . >/dev/null 2>&1; then
    VERIFY_SCAN=$(echo "$VERIFY_RESPONSE" | jq -r '.configurations[]? | select(.scanName == "acs-catch-all") | .id' 2>/dev/null | head -1)
    
    if [ -n "$VERIFY_SCAN" ] && [ "$VERIFY_SCAN" != "null" ]; then
        SCAN_CONFIG_ID="$VERIFY_SCAN"
        log "✓ Scan configuration verified (ID: $SCAN_CONFIG_ID)"
    else
        warning "Scan configuration 'acs-catch-all' not found in verification check"
        warning "Available scan configurations:"
        echo "$VERIFY_RESPONSE" | jq -r '.configurations[]? | "  - \(.scanName) (ID: \(.id))"' 2>/dev/null || echo "  (none found)"
        error "Scan configuration was not created successfully. Please check the API response above."
    fi
else
    warning "Could not verify scan configuration (this may be non-fatal)"
    if [ -n "$SCAN_CONFIG_ID" ] && [ "$SCAN_CONFIG_ID" != "null" ]; then
        log "Using scan configuration ID from creation response: $SCAN_CONFIG_ID"
    fi
fi

log ""
log "========================================================="
log "Compliance Scan Schedule Setup Completed!"
log "========================================================="
log "Scan Configuration Name: acs-catch-all"
if [ -n "$SCAN_CONFIG_ID" ] && [ "$SCAN_CONFIG_ID" != "null" ]; then
    log "Scan Configuration ID: $SCAN_CONFIG_ID"
fi
log "Clusters included ($CLUSTER_COUNT):"
echo "$CLUSTER_NAMES" | while read -r line; do
    log "  - $line"
done
log "Profiles: ocp4-cis, ocp4-cis-node, ocp4-moderate, ocp4-moderate-node, ocp4-e8, ocp4-high, ocp4-high-node, ocp4-nerc-cip, ocp4-nerc-cip-node, ocp4-pci-dss, ocp4-pci-dss-node, ocp4-stig, ocp4-bsi, ocp4-pci-dss-4-0"
log "Schedule: Daily at 12:00"
log "========================================================="
log ""
log "The compliance scan schedule has been created in ACS Central."
log "The scan will run automatically on the configured schedule for all $CLUSTER_COUNT cluster(s)."
log ""
