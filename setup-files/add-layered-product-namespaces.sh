#!/bin/bash
# Add Layered Product Namespaces Script for RHACS
# Adds specified namespaces to the Red Hat layered products platform component rule

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[LAYERED-PRODUCTS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[LAYERED-PRODUCTS]${NC} $1"
}

error() {
    echo -e "${RED}[LAYERED-PRODUCTS] ERROR:${NC} $1" >&2
    echo -e "${RED}[LAYERED-PRODUCTS] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
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

# Prepare API base URL
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT#https://}"
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT_FOR_API#http://}"
API_BASE="https://${ROX_ENDPOINT_FOR_API}/v1"

# Function to make API call
make_api_call() {
    local method=$1
    local endpoint=$2
    local data="${3:-}"
    local description="${4:-API call}"
    
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
    
    curl_cmd="$curl_cmd \"$API_BASE/$endpoint\""
    
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

# Namespaces to add to layered products
NAMESPACES_TO_ADD=(
    "cert-manager"
    "open-cluster-management-hub"
    "open-cluster-management-agent-addon"
    "openshift-gitops"
    "quay"
    "openshift-pipelines"
    "openshift-operator-controller"
    "openshift-catalogd"
)

log "========================================================="
log "Adding Layered Product Namespaces to RHACS Configuration"
log "========================================================="
log ""
log "Namespaces to add:"
for ns in "${NAMESPACES_TO_ADD[@]}"; do
    log "  - $ns"
done
log ""

# Get current configuration
log "Retrieving current RHACS configuration..."
CURRENT_CONFIG=$(make_api_call "GET" "config" "" "Get current configuration")
log "✓ Configuration retrieved"

# Extract current layered products regex
CURRENT_REGEX=$(echo "$CURRENT_CONFIG" | jq -r '.config.platformComponentConfig.rules[] | select(.name == "red hat layered products") | .namespaceRule.regex' 2>/dev/null || echo "")

if [ -z "$CURRENT_REGEX" ] || [ "$CURRENT_REGEX" = "null" ]; then
    error "Could not find 'red hat layered products' rule in current configuration"
fi

log "✓ Current layered products regex found (length: ${#CURRENT_REGEX} chars)"

# Check which namespaces are already in the regex
log "Checking which namespaces are already configured..."
for ns in "${NAMESPACES_TO_ADD[@]}"; do
    # Escape namespace for regex check
    ESCAPED_NS=$(echo "$ns" | sed 's/[.*+?^${}()|[]/\\&/g')
    if echo "$CURRENT_REGEX" | grep -q "\\^${ESCAPED_NS}\\$"; then
        log "  - $ns: already configured"
    else
        log "  - $ns: needs to be added"
    fi
done

# Build new regex by appending namespaces that aren't already present
NEW_REGEX="$CURRENT_REGEX"
NAMESPACES_ADDED=0

for ns in "${NAMESPACES_TO_ADD[@]}"; do
    # Escape namespace for regex
    ESCAPED_NS=$(echo "$ns" | sed 's/[.*+?^${}()|[]/\\&/g')
    # Check if namespace is already in regex (format: ^namespace$)
    if ! echo "$NEW_REGEX" | grep -q "\\^${ESCAPED_NS}\\$"; then
        # Append to regex with | separator
        if [ "$NEW_REGEX" != "${NEW_REGEX%|}" ]; then
            NEW_REGEX="${NEW_REGEX}|^${ns}\$"
        else
            NEW_REGEX="${NEW_REGEX}|^${ns}\$"
        fi
        NAMESPACES_ADDED=$((NAMESPACES_ADDED + 1))
        log "  ✓ Added $ns to regex"
    fi
done

if [ $NAMESPACES_ADDED -eq 0 ]; then
    log ""
    log "All specified namespaces are already configured in the layered products rule."
    log "No changes needed."
    exit 0
fi

log ""
log "Updated regex will add $NAMESPACES_ADDED namespace(s)"

# Build updated configuration payload
log "Building updated configuration payload..."
UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | jq --arg new_regex "$NEW_REGEX" '
    .config.platformComponentConfig.rules = (
        .config.platformComponentConfig.rules | map(
            if .name == "red hat layered products" then
                .namespaceRule.regex = $new_regex
            else
                .
            end
        )
    )
')

# Update configuration
log "Updating RHACS configuration..."
CONFIG_RESPONSE=$(make_api_call "PUT" "config" "$UPDATED_CONFIG" "Update RHACS configuration")
log "✓ Configuration updated successfully"

# Validate configuration changes
log "Validating configuration changes..."
VALIDATED_CONFIG=$(make_api_call "GET" "config" "" "Validate configuration")
log "✓ Configuration validated"

# Verify the changes
log "Verifying updated layered products regex..."
VERIFIED_REGEX=$(echo "$VALIDATED_CONFIG" | jq -r '.config.platformComponentConfig.rules[] | select(.name == "red hat layered products") | .namespaceRule.regex' 2>/dev/null || echo "")

if [ -z "$VERIFIED_REGEX" ] || [ "$VERIFIED_REGEX" = "null" ]; then
    error "Failed to verify updated configuration"
fi

log "✓ Verified updated regex (length: ${#VERIFIED_REGEX} chars)"

# Check that all namespaces are now present
log ""
log "Verifying all namespaces are configured..."
ALL_PRESENT=true
for ns in "${NAMESPACES_TO_ADD[@]}"; do
    ESCAPED_NS=$(echo "$ns" | sed 's/[.*+?^${}()|[]/\\&/g')
    if echo "$VERIFIED_REGEX" | grep -q "\\^${ESCAPED_NS}\\$"; then
        log "  ✓ $ns: configured"
    else
        log "  ✗ $ns: NOT found in configuration"
        ALL_PRESENT=false
    fi
done

if [ "$ALL_PRESENT" = false ]; then
    warning "Some namespaces were not found in the verified configuration"
    warning "This may indicate a configuration issue"
fi

log ""
log "========================================================="
log "Layered Product Namespaces Configuration Completed"
log "========================================================="
log ""
log "Summary:"
log "  - Added $NAMESPACES_ADDED namespace(s) to layered products rule"
log "  - Configuration updated and validated"
log "  - All specified namespaces are now marked as platform components"
log ""
log "The following namespaces are now configured as layered products:"
for ns in "${NAMESPACES_TO_ADD[@]}"; do
    log "  - $ns"
done
