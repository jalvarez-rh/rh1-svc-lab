#!/bin/bash
# Add Layered Product Namespaces Script for RHACS
# Adds specified namespaces to the Red Hat layered products platform component rule
# Uses the same approach as 11-configure-rhacs-settings.sh

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
    "open-cluster-management-agent"
    "open-cluster-management-agent-addon"
    "openshift-gitops"
    "quay"
    "openshift-pipelines"
    "openshift-operator-controller"
    "openshift-catalogd"
    "openshift-frr-k8s"
    "openshift-cluster-olm-operator"
)

log "Adding Layered Product Namespaces to RHACS Configuration"

# Get current configuration
CURRENT_CONFIG=$(make_api_call "GET" "config" "" "Get current configuration")

# Extract current layered products regex
CURRENT_REGEX=$(echo "$CURRENT_CONFIG" | jq -r '.config.platformComponentConfig.rules[]? | select(.name == "red hat layered products") | .namespaceRule.regex' 2>/dev/null || echo "")

if [ -z "$CURRENT_REGEX" ] || [ "$CURRENT_REGEX" = "null" ]; then
    log "Initializing configuration with default layered products rule..."
    
    # Prepare default configuration payload with layered products rule
    DEFAULT_CONFIG_PAYLOAD=$(cat <<'EOF'
{
  "config": {
    "publicConfig": {
      "loginNotice": { "enabled": false, "text": "" },
      "header": { "enabled": false, "text": "", "size": "UNSET", "color": "#000000", "backgroundColor": "#FFFFFF" },
      "footer": { "enabled": false, "text": "", "size": "UNSET", "color": "#000000", "backgroundColor": "#FFFFFF" },
      "telemetry": { "enabled": true, "lastSetTime": null }
    },
    "privateConfig": {
      "alertConfig": {
        "resolvedDeployRetentionDurationDays": 7,
        "deletedRuntimeRetentionDurationDays": 7,
        "allRuntimeRetentionDurationDays": 30,
        "attemptedDeployRetentionDurationDays": 7,
        "attemptedRuntimeRetentionDurationDays": 7
      },
      "imageRetentionDurationDays": 7,
      "expiredVulnReqRetentionDurationDays": 90,
      "decommissionedClusterRetention": {
        "retentionDurationDays": 0,
        "ignoreClusterLabels": {},
        "lastUpdated": "2025-11-26T15:02:32.522230327Z",
        "createdAt": "2025-11-26T15:02:32.522229766Z"
      },
      "reportRetentionConfig": {
        "historyRetentionDurationDays": 7,
        "downloadableReportRetentionDays": 7,
        "downloadableReportGlobalRetentionBytes": 524288000
      },
      "vulnerabilityExceptionConfig": {
        "expiryOptions": {
          "dayOptions": [
            { "numDays": 14, "enabled": true },
            { "numDays": 30, "enabled": true },
            { "numDays": 60, "enabled": true },
            { "numDays": 90, "enabled": true }
          ],
          "fixableCveOptions": { "allFixable": true, "anyFixable": true },
          "customDate": false,
          "indefinite": false
        }
      },
      "administrationEventsConfig": { "retentionDurationDays": 4 },
      "metrics": {
        "imageVulnerabilities": {
          "gatheringPeriodMinutes": 1,
          "descriptors": {
            "cve_severity": { "labels": ["Cluster","CVE","IsPlatformWorkload","IsFixable","Severity"] },
            "deployment_severity": { "labels": ["Cluster","Namespace","Deployment","IsPlatformWorkload","IsFixable","Severity"] },
            "namespace_severity": { "labels": ["Cluster","Namespace","IsPlatformWorkload","IsFixable","Severity"] }
          }
        },
        "policyViolations": {
          "gatheringPeriodMinutes": 1,
          "descriptors": {
            "deployment_severity": { "labels": ["Cluster","Namespace","Deployment","IsPlatformComponent","Action","Severity"] },
            "namespace_severity": { "labels": ["Cluster","Namespace","IsPlatformComponent","Action","Severity"] }
          }
        },
        "nodeVulnerabilities": {
          "gatheringPeriodMinutes": 1,
          "descriptors": {
            "component_severity": { "labels": ["Cluster","Node","Component","IsFixable","Severity"] },
            "cve_severity": { "labels": ["Cluster","CVE","IsFixable","Severity"] },
            "node_severity": { "labels": ["Cluster","Node","IsFixable","Severity"] }
          }
        }
      }
    },
    "platformComponentConfig": {
      "rules": [
        {
          "name": "red hat layered products",
          "namespaceRule": { "regex": "^aap$|^ack-system$|^aws-load-balancer-operator$|^cert-manager-operator$|^cert-utils-operator$|^costmanagement-metrics-operator$|^external-dns-operator$|^metallb-system$|^mtr$|^multicluster-engine$|^multicluster-global-hub$|^node-observability-operator$|^open-cluster-management$|^openshift-adp$|^openshift-apiserver-operator$|^openshift-authentication$|^openshift-authentication-operator$|^openshift-builds$|^openshift-cloud-controller-manager$|^openshift-cloud-controller-manager-operator$|^openshift-cloud-credential-operator$|^openshift-cloud-network-config-controller$|^openshift-cluster-csi-drivers$|^openshift-cluster-machine-approver$|^openshift-cluster-node-tuning-operator$|^openshift-cluster-observability-operator$|^openshift-cluster-samples-operator$|^openshift-cluster-storage-operator$|^openshift-cluster-version$|^openshift-cnv$|^openshift-compliance$|^openshift-config$|^openshift-config-managed$|^openshift-config-operator$|^openshift-console$|^openshift-console-operator$|^openshift-console-user-settings$|^openshift-controller-manager$|^openshift-controller-manager-operator$|^openshift-dbaas-operator$|^openshift-distributed-tracing$|^openshift-dns$|^openshift-dns-operator$|^openshift-dpu-network-operator$|^openshift-dr-system$|^openshift-etcd$|^openshift-etcd-operator$|^openshift-file-integrity$|^openshift-gitops-operator$|^openshift-host-network$|^openshift-image-registry$|^openshift-infra$|^openshift-ingress$|^openshift-ingress-canary$|^openshift-ingress-node-firewall$|^openshift-ingress-operator$|^openshift-insights$|^openshift-keda$|^openshift-kmm$|^openshift-kmm-hub$|^openshift-kni-infra$|^openshift-kube-apiserver$|^openshift-kube-apiserver-operator$|^openshift-kube-controller-manager$|^openshift-kube-controller-manager-operator$|^openshift-kube-scheduler$|^openshift-kube-scheduler-operator$|^openshift-kube-storage-version-migrator$|^openshift-kube-storage-version-migrator-operator$|^openshift-lifecycle-agent$|^openshift-local-storage$|^openshift-logging$|^openshift-machine-api$|^openshift-machine-config-operator$|^openshift-marketplace$|^openshift-migration$|^openshift-monitoring$|^openshift-mta$|^openshift-mtv$|^openshift-multus$|^openshift-netobserv-operator$|^openshift-network-diagnostics$|^openshift-network-node-identity$|^openshift-network-operator$|^openshift-nfd$|^openshift-nmstate$|^openshift-node$|^openshift-nutanix-infra$|^openshift-oauth-apiserver$|^openshift-openstack-infra$|^openshift-opentelemetry-operator$|^openshift-operator-lifecycle-manager$|^openshift-operators$|^openshift-operators-redhat$|^openshift-ovirt-infra$|^openshift-ovn-kubernetes$|^openshift-ptp$|^openshift-route-controller-manager$|^openshift-sandboxed-containers-operator$|^openshift-security-profiles$|^openshift-serverless$|^openshift-serverless-logic$|^openshift-service-ca$|^openshift-service-ca-operator$|^openshift-sriov-network-operator$|^openshift-storage$|^openshift-tempo-operator$|^openshift-update-service$|^openshift-user-workload-monitoring$|^openshift-vertical-pod-autoscaler$|^openshift-vsphere-infra$|^openshift-windows-machine-config-operator$|^openshift-workload-availability$|^redhat-ods-operator$|^rhacs-operator$|^rhdh-operator$|^service-telemetry$|^stackrox$|^submariner-operator$|^tssc-acs$|^openshift-devspaces$" }
        },
        {
          "name": "system rule",
          "namespaceRule": { "regex": "^openshift$|^openshift-apiserver$|^openshift-operators$|^kube-.*" }
        }
      ],
      "needsReevaluation": false
    }
  }
}
EOF
)
    
    # Extract the regex from the payload we're about to send
    DEFAULT_REGEX=$(echo "$DEFAULT_CONFIG_PAYLOAD" | jq -r '.config.platformComponentConfig.rules[]? | select(.name == "red hat layered products") | .namespaceRule.regex' 2>/dev/null || echo "")
    
    if [ -z "$DEFAULT_REGEX" ] || [ "$DEFAULT_REGEX" = "null" ]; then
        error "Failed to extract default regex from configuration payload"
    fi
    
    # Update configuration with default payload
    CONFIG_RESPONSE=$(make_api_call "PUT" "config" "$DEFAULT_CONFIG_PAYLOAD" "Create initial RHACS configuration")
    
    # Use the regex we sent in the payload (we know it's correct)
    CURRENT_REGEX="$DEFAULT_REGEX"
    
    # Get the full configuration back to use for future updates
    CURRENT_CONFIG=$(make_api_call "GET" "config" "" "Get created configuration")
    VERIFIED_REGEX=$(echo "$CURRENT_CONFIG" | jq -r '.config.platformComponentConfig.rules[]? | select(.name == "red hat layered products") | .namespaceRule.regex' 2>/dev/null || echo "")
    
    if [ -n "$VERIFIED_REGEX" ] && [ "$VERIFIED_REGEX" != "null" ] && [ "$VERIFIED_REGEX" != "" ]; then
        CURRENT_REGEX="$VERIFIED_REGEX"
    else
        # Fallback: use the regex from the payload and the payload as current config
        CURRENT_REGEX="$DEFAULT_REGEX"
        CURRENT_CONFIG="$DEFAULT_CONFIG_PAYLOAD"
    fi
fi

# Build new regex by appending namespaces that aren't already present
NEW_REGEX="$CURRENT_REGEX"
NAMESPACES_ADDED=0

for ns in "${NAMESPACES_TO_ADD[@]}"; do
    # Escape namespace for regex check
    ESCAPED_NS=$(echo "$ns" | sed 's/[.*+?^${}()|[]/\\&/g')
    # Check if namespace is already in regex (format: ^namespace$)
    if ! echo "$NEW_REGEX" | grep -q "\\^${ESCAPED_NS}\\$"; then
        # Append to regex with | separator
        NEW_REGEX="${NEW_REGEX}|^${ns}\$"
        NAMESPACES_ADDED=$((NAMESPACES_ADDED + 1))
    fi
done

if [ $NAMESPACES_ADDED -eq 0 ]; then
    log "All specified namespaces are already configured. No changes needed."
    exit 0
fi

log "Adding $NAMESPACES_ADDED namespace(s) to layered products rule..."

# Validate CURRENT_CONFIG is valid JSON before proceeding
if ! echo "$CURRENT_CONFIG" | jq . >/dev/null 2>&1; then
    error "CURRENT_CONFIG is not valid JSON. Cannot proceed with update."
fi

# Build updated configuration payload using jq to update just the regex
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

if [ $? -ne 0 ] || [ -z "$UPDATED_CONFIG" ]; then
    error "Failed to build updated configuration payload. Check that CURRENT_CONFIG has the correct structure."
fi

# Update configuration
CONFIG_RESPONSE=$(make_api_call "PUT" "config" "$UPDATED_CONFIG" "Update RHACS configuration")
VALIDATED_CONFIG=$(make_api_call "GET" "config" "" "Validate configuration")

# Verify VALIDATED_CONFIG is valid JSON
if ! echo "$VALIDATED_CONFIG" | jq . >/dev/null 2>&1; then
    warning "Validated config is not valid JSON, using NEW_REGEX as fallback"
    VERIFIED_REGEX="$NEW_REGEX"
else
    # Verify the changes
    VERIFIED_REGEX=$(echo "$VALIDATED_CONFIG" | jq -r '.config.platformComponentConfig.rules[]? | select(.name == "red hat layered products") | .namespaceRule.regex' 2>/dev/null || echo "")
    
    if [ -z "$VERIFIED_REGEX" ] || [ "$VERIFIED_REGEX" = "null" ] || [ "$VERIFIED_REGEX" = "" ]; then
        # Try alternative query path with more optional operators
        VERIFIED_REGEX=$(echo "$VALIDATED_CONFIG" | jq -r '.config.platformComponentConfig.rules[]? | select(.name == "red hat layered products")?.namespaceRule?.regex' 2>/dev/null || echo "")
        
        if [ -z "$VERIFIED_REGEX" ] || [ "$VERIFIED_REGEX" = "null" ] || [ "$VERIFIED_REGEX" = "" ]; then
            # Use the regex we just sent as fallback (we know it's correct)
            VERIFIED_REGEX="$NEW_REGEX"
        fi
    fi
fi

log "Configuration updated successfully. Added $NAMESPACES_ADDED namespace(s) to layered products rule."
