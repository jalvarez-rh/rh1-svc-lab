#!/bin/bash
# Compliance Management Scan Trigger Script
# Triggers compliance scans for multiple standards (CIS Kubernetes v1.5, HIPAA 164, NIST SP 800-190, NIST SP 800-53, PCI DSS 3.2.1)
# for the Production cluster in Red Hat Advanced Cluster Security

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[COMPLIANCE-SCAN]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[COMPLIANCE-SCAN]${NC} $1"
}

error() {
    echo -e "${RED}[COMPLIANCE-SCAN] ERROR:${NC} $1" >&2
    echo -e "${RED}[COMPLIANCE-SCAN] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Set script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# RHACS operator namespace
RHACS_OPERATOR_NAMESPACE="rhacs-operator"

# Generate ROX_ENDPOINT from Central route
log "Extracting ROX_ENDPOINT from Central route..."
CENTRAL_ROUTE=$(oc get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$CENTRAL_ROUTE" ]; then
    error "Central route not found in namespace '$RHACS_OPERATOR_NAMESPACE'. Please ensure RHACS Central is installed."
fi
ROX_ENDPOINT="$CENTRAL_ROUTE"
log "✓ Extracted ROX_ENDPOINT: $ROX_ENDPOINT"

# Generate ROX_API_TOKEN (same method as script 09)
log "Generating API token..."
ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
if [ -z "$ADMIN_PASSWORD_B64" ]; then
    error "Admin password secret 'central-htpasswd' not found in namespace '$RHACS_OPERATOR_NAMESPACE'"
fi
ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)

# Normalize ROX_ENDPOINT for API calls
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

# Download roxctl if not available (Linux bastion host)
ROXCTL_CMD=""
if ! command -v roxctl &>/dev/null; then
    log "roxctl not found, downloading..."
    
    RHACS_VERSION=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Advanced Cluster Security for Kubernetes")].spec.version}' 2>/dev/null || echo "")
    if [ -z "$RHACS_VERSION" ]; then
        RHACS_VERSION=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[0].spec.version}' 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || echo "latest")
    fi
    
    ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/${RHACS_VERSION}/bin/Linux/roxctl"
    ROXCTL_TMP="/tmp/roxctl"
    
    log "Downloading roxctl from: $ROXCTL_URL"
    if ! curl -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL" 2>/dev/null; then
        ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
        log "Retrying with latest version: $ROXCTL_URL"
        if ! curl -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL" 2>/dev/null; then
            error "Failed to download roxctl. Please install it manually."
        fi
    fi
    
    chmod +x "$ROXCTL_TMP"
    ROXCTL_CMD="$ROXCTL_TMP"
    log "✓ roxctl downloaded to $ROXCTL_TMP"
else
    ROXCTL_CMD="roxctl"
    log "✓ roxctl found in PATH"
fi

# Generate token using API directly with basic auth (more reliable than roxctl)
log "Generating API token using Central API..."
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT#https://}"
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT_FOR_API#http://}"

set +e
TOKEN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X POST \
    -u "admin:${ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/generate" \
    -d '{"name":"script-generated-token-trigger","roles":["Admin"]}' 2>&1)
TOKEN_CURL_EXIT_CODE=$?
set -e

if [ $TOKEN_CURL_EXIT_CODE -ne 0 ]; then
    log "API token generation via curl failed, trying roxctl..."
    set +e
    TOKEN_OUTPUT=$($ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
        central token generate \
        --password "$ADMIN_PASSWORD" \
        --insecure-skip-tls-verify 2>&1)
    TOKEN_EXIT_CODE=$?
    set -e
    
    if [ $TOKEN_EXIT_CODE -ne 0 ]; then
        error "Failed to generate API token. roxctl output: ${TOKEN_OUTPUT:0:500}"
    fi
    
    ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
    if [ -z "$ROX_API_TOKEN" ]; then
        ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | tail -1 | tr -d '[:space:]' || echo "")
    fi
    
    if [ -z "$ROX_API_TOKEN" ]; then
        error "Failed to extract API token from roxctl output. Output: ${TOKEN_OUTPUT:0:500}"
    fi
else
    # Extract token from API response
    if echo "$TOKEN_RESPONSE" | jq . >/dev/null 2>&1; then
        ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .data.token // empty' 2>/dev/null || echo "")
    fi
    
    if [ -z "$ROX_API_TOKEN" ] || [ "$ROX_API_TOKEN" = "null" ]; then
        ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
    fi
    
    if [ -z "$ROX_API_TOKEN" ]; then
        log "Failed to extract token from API response, trying roxctl fallback..."
        set +e
        TOKEN_OUTPUT=$($ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
            central token generate \
            --password "$ADMIN_PASSWORD" \
            --insecure-skip-tls-verify 2>&1)
        TOKEN_EXIT_CODE=$?
        set -e
        
        if [ $TOKEN_EXIT_CODE -eq 0 ]; then
            ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
            if [ -z "$ROX_API_TOKEN" ]; then
                ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | tail -1 | tr -d '[:space:]' || echo "")
            fi
        fi
    fi
    
    if [ -z "$ROX_API_TOKEN" ]; then
        error "Failed to extract API token. API Response: ${TOKEN_RESPONSE:0:500}"
    fi
fi

# Verify token is not empty and has reasonable length
if [ ${#ROX_API_TOKEN} -lt 20 ]; then
    error "Generated token appears to be invalid (too short: ${#ROX_API_TOKEN} chars)"
fi

log "✓ API token generated (length: ${#ROX_API_TOKEN} chars)"

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
        error "jq is required for this script to work correctly. Please install jq manually."
    fi
    log "✓ jq installed successfully"
else
    log "✓ jq is already installed"
fi

# Ensure ROX_ENDPOINT has https:// prefix
if [[ ! "$ROX_ENDPOINT" =~ ^https?:// ]]; then
    ROX_ENDPOINT="https://$ROX_ENDPOINT"
    log "Added https:// prefix to ROX_ENDPOINT: $ROX_ENDPOINT"
fi

# API endpoints
CLUSTERS_ENDPOINT="${ROX_ENDPOINT}/v1/clusters"
STANDARDS_ENDPOINT="${ROX_ENDPOINT}/v1/compliance/standards"
SCAN_ENDPOINT="${ROX_ENDPOINT}/v1/compliancemanagement/runs"

# Function to make API call
make_api_call() {
    local method=$1
    local endpoint=$2
    local data="${3:-}"
    local description="${4:-API call}"
    
    # Redirect log to stderr so it's not captured in response
    log "Making $description: $method $endpoint" >&2
    
    local temp_file=""
    local curl_cmd="curl -k -s -w \"\n%{http_code}\" -X $method"
    curl_cmd="$curl_cmd -H \"Authorization: Bearer $ROX_API_TOKEN\""
    curl_cmd="$curl_cmd -H \"Content-Type: application/json\""
    
    if [ -n "$data" ]; then
        # For multi-line JSON, use a temporary file to avoid quoting issues
        if echo "$data" | grep -q $'\n'; then
            temp_file=$(mktemp)
            echo "$data" > "$temp_file"
            curl_cmd="$curl_cmd --data-binary @\"$temp_file\""
        else
            # Single-line data can use -d directly
            curl_cmd="$curl_cmd -d '$data'"
        fi
    fi
    
    curl_cmd="$curl_cmd \"$endpoint\""
    
    local response=$(eval "$curl_cmd" 2>&1)
    local exit_code=$?
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n -1)
    
    # Clean up temp file if used
    if [ -n "$temp_file" ] && [ -f "$temp_file" ]; then
        rm -f "$temp_file"
    fi
    
    if [ $exit_code -ne 0 ]; then
        error "$description failed (curl exit code: $exit_code). Response: ${body:0:500}"
    fi
    
    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        error "$description failed (HTTP $http_code). Response: ${body:0:500}"
    fi
    
    echo "$body"
}

# Fetch cluster ID - look for "Production" cluster (capital P)
log "========================================================="
log "Finding Production cluster..."
log "========================================================="

CLUSTER_RESPONSE=$(make_api_call "GET" "$CLUSTERS_ENDPOINT" "" "Fetch clusters")

if [ -z "$CLUSTER_RESPONSE" ]; then
    error "Empty response from cluster API"
fi

# Parse cluster response
if ! echo "$CLUSTER_RESPONSE" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from cluster API. Response: ${CLUSTER_RESPONSE:0:300}"
fi

# Try to find cluster by name "Production" (capital P as it appears in RHACS)
EXPECTED_CLUSTER_NAME="Production"
CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.name == \"$EXPECTED_CLUSTER_NAME\") | .id" 2>/dev/null | head -1)

if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" = "null" ]; then
    # Try case-insensitive match as fallback
    log "Cluster 'Production' not found (case-sensitive), trying case-insensitive match..."
    CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.name | ascii_downcase == \"production\") | .id" 2>/dev/null | head -1)
    
    if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" = "null" ]; then
        error "Production cluster not found. Available clusters: $(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[] | "\(.name): \(.id)"' 2>/dev/null | tr '\n' ' ' || echo "none")"
    else
        CLUSTER_NAME=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$CLUSTER_ID\") | .name" 2>/dev/null | head -1)
        log "Found cluster with case-insensitive match: $CLUSTER_NAME"
    fi
fi

# Verify cluster exists and get its name for logging
if [ -z "${CLUSTER_NAME:-}" ] || [ "${CLUSTER_NAME:-}" = "null" ]; then
    CLUSTER_NAME=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$CLUSTER_ID\") | .name" 2>/dev/null | head -1)
fi

CLUSTER_HEALTH=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$CLUSTER_ID\") | .healthStatus.overallHealthStatus // \"UNKNOWN\"" 2>/dev/null | head -1)

if [ -n "$CLUSTER_NAME" ] && [ "$CLUSTER_NAME" != "null" ]; then
    log "✓ Found Production cluster: $CLUSTER_NAME (ID: $CLUSTER_ID, Health: ${CLUSTER_HEALTH:-UNKNOWN})"
else
    log "✓ Using cluster ID: $CLUSTER_ID"
fi

# Verify cluster is connected (not disconnected)
CLUSTER_STATUS=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$CLUSTER_ID\") | .status.connectionStatus // \"UNKNOWN\"" 2>/dev/null | head -1)
if [ "$CLUSTER_STATUS" = "DISCONNECTED" ] || [ "$CLUSTER_STATUS" = "UNINITIALIZED" ]; then
    warning "Cluster $CLUSTER_NAME (ID: $CLUSTER_ID) has status: $CLUSTER_STATUS"
    warning "This may cause scan failures. Ensure the cluster is properly connected to RHACS."
fi

# Define compliance standards to trigger scans for
declare -a COMPLIANCE_STANDARDS=(
    "CIS Kubernetes v1.5"
    "HIPAA 164"
    "NIST SP 800-190"
    "NIST SP 800-53"
    "PCI DSS 3.2.1"
)

# Fetch compliance standards
log ""
log "========================================================="
log "Finding compliance standards..."
log "========================================================="

log "Fetching available compliance standards..."

# Try the compliance standards endpoint
set +e
STANDARDS_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X GET \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    "$STANDARDS_ENDPOINT" 2>&1) || true
set -e

HTTP_CODE=$(echo "$STANDARDS_RESPONSE" | tail -n1)
STANDARDS_BODY=$(echo "$STANDARDS_RESPONSE" | head -n -1)

if [ "$HTTP_CODE" -ne 200 ] || [ -z "$STANDARDS_BODY" ]; then
    error "Failed to fetch standards (HTTP $HTTP_CODE). Response: ${STANDARDS_BODY:0:300}"
fi

if ! echo "$STANDARDS_BODY" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from standards API. Response: ${STANDARDS_BODY:0:300}"
fi

# List all available standards for debugging
log "Available compliance standards:"
echo "$STANDARDS_BODY" | jq -r 'if type == "array" then .[] | "  - \(.name // .id): \(.id)" elif .standards then .standards[]? | "  - \(.name // .id): \(.id)" else .[]? | "  - \(.name // .id): \(.id)" end' 2>/dev/null || \
log "  Could not parse standards list"

# Function to find standard ID by name pattern
find_standard_id() {
    local search_name="$1"
    local standard_id=""
    
    # Try exact match first
    standard_id=$(echo "$STANDARDS_BODY" | jq -r "if type == \"array\" then .[] | select(.name == \"$search_name\") | .id elif .standards then .standards[]? | select(.name == \"$search_name\") | .id else .[]? | select(.name == \"$search_name\") | .id end" 2>/dev/null | head -1)
    
    # Try case-insensitive match
    if [ -z "$standard_id" ] || [ "$standard_id" = "null" ]; then
        standard_id=$(echo "$STANDARDS_BODY" | jq -r "if type == \"array\" then .[] | select(.name | ascii_downcase == \"$(echo "$search_name" | tr '[:upper:]' '[:lower:]')\") | .id elif .standards then .standards[]? | select(.name | ascii_downcase == \"$(echo "$search_name" | tr '[:upper:]' '[:lower:]')\") | .id else .[]? | select(.name | ascii_downcase == \"$(echo "$search_name" | tr '[:upper:]' '[:lower:]')\") | .id end" 2>/dev/null | head -1)
    fi
    
    # Try pattern matching for partial names
    if [ -z "$standard_id" ] || [ "$standard_id" = "null" ]; then
        # Build regex pattern from search name (escape special chars and make flexible)
        local pattern=$(echo "$search_name" | sed 's/[.*+?^${}()|[\]\\]/\\&/g' | sed 's/ /.*/g')
        standard_id=$(echo "$STANDARDS_BODY" | jq -r "if type == \"array\" then .[] | select(.name | test(\"$pattern\"; \"i\")) | .id elif .standards then .standards[]? | select(.name | test(\"$pattern\"; \"i\")) | .id else .[]? | select(.name | test(\"$pattern\"; \"i\")) | .id end" 2>/dev/null | head -1)
    fi
    
    echo "$standard_id"
}

# Find all required standards
declare -A STANDARD_IDS
declare -A STANDARD_NAMES
FOUND_COUNT=0

for standard_name in "${COMPLIANCE_STANDARDS[@]}"; do
    standard_id=$(find_standard_id "$standard_name")
    
    if [ -n "$standard_id" ] && [ "$standard_id" != "null" ]; then
        STANDARD_IDS["$standard_name"]="$standard_id"
        # Get the actual name from the response
        actual_name=$(echo "$STANDARDS_BODY" | jq -r "if type == \"array\" then .[] | select(.id == \"$standard_id\") | .name elif .standards then .standards[]? | select(.id == \"$standard_id\") | .name else .[]? | select(.id == \"$standard_id\") | .name end" 2>/dev/null || echo "$standard_name")
        STANDARD_NAMES["$standard_name"]="$actual_name"
        log "✓ Found $standard_name: $actual_name (ID: $standard_id)"
        FOUND_COUNT=$((FOUND_COUNT + 1))
    else
        warning "Standard '$standard_name' not found in available standards"
    fi
done

if [ $FOUND_COUNT -eq 0 ]; then
    error "Could not find any of the required compliance standards. Available standards listed above."
fi

log ""
log "Found $FOUND_COUNT out of ${#COMPLIANCE_STANDARDS[@]} required standards"

# Trigger compliance scans for all found standards
log ""
log "========================================================="
log "Triggering compliance scans..."
log "========================================================="
log "Endpoint: $SCAN_ENDPOINT"
log "Cluster: $CLUSTER_NAME (ID: $CLUSTER_ID)"
log ""

SUCCESS_COUNT=0
FAILED_COUNT=0

for standard_name in "${COMPLIANCE_STANDARDS[@]}"; do
    if [ -z "${STANDARD_IDS[$standard_name]:-}" ]; then
        warning "Skipping '$standard_name' - standard ID not found"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi
    
    standard_id="${STANDARD_IDS[$standard_name]}"
    actual_name="${STANDARD_NAMES[$standard_name]}"
    
    log "Triggering scan for: $actual_name (ID: $standard_id)..."
    
    # Prepare scan request payload
    SCAN_PAYLOAD=$(cat <<EOF
{
  "selection": {
    "clusterId": "$CLUSTER_ID",
    "standardId": "$standard_id"
  }
}
EOF
)
    
    # Make POST request to trigger the scan
    set +e
    SCAN_RESPONSE=$(make_api_call "POST" "$SCAN_ENDPOINT" "$SCAN_PAYLOAD" "Trigger $actual_name compliance scan" 2>&1)
    SCAN_EXIT_CODE=$?
    set -e
    
    if [ $SCAN_EXIT_CODE -eq 0 ]; then
        log "✓ $actual_name scan triggered successfully"
        
        # Try to extract scan ID or status if present
        if echo "$SCAN_RESPONSE" | jq . >/dev/null 2>&1; then
            SCAN_ID=$(echo "$SCAN_RESPONSE" | jq -r '.id // .scanId // .runId // empty' 2>/dev/null || echo "")
            if [ -n "$SCAN_ID" ] && [ "$SCAN_ID" != "null" ]; then
                log "  Scan ID: $SCAN_ID"
            fi
        fi
        
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        warning "Failed to trigger scan for $actual_name"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    
    # Small delay between scans
    sleep 1
done

log ""
log "========================================================="
log "Compliance Scan Trigger Summary"
log "========================================================="
log "Cluster: $CLUSTER_NAME (ID: $CLUSTER_ID)"
log "Standards found: $FOUND_COUNT/${#COMPLIANCE_STANDARDS[@]}"
log "Scans triggered successfully: $SUCCESS_COUNT"
if [ $FAILED_COUNT -gt 0 ]; then
    warning "Scans failed: $FAILED_COUNT"
fi
log ""
log "Triggered scans:"
for standard_name in "${COMPLIANCE_STANDARDS[@]}"; do
    if [ -n "${STANDARD_IDS[$standard_name]:-}" ]; then
        log "  ✓ ${STANDARD_NAMES[$standard_name]}"
    else
        log "  ✗ $standard_name (not found)"
    fi
done
log ""
log "The scans are now running. They may take several minutes to complete."
log "You can monitor progress in RHACS UI: Compliance → Coverage tab"
log ""
