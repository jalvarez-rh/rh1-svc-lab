#!/bin/bash
# ACS Cleanup Script
# Removes all RHACS operator resources from the aws-us cluster

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[ACS-CLEANUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[ACS-CLEANUP]${NC} $1"
}

error() {
    echo -e "${RED}[ACS-CLEANUP] ERROR:${NC} $1" >&2
    echo -e "${RED}[ACS-CLEANUP] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Detect kubectl command
if command -v oc >/dev/null 2>&1; then
    KUBECTL_CMD="oc"
elif command -v kubectl >/dev/null 2>&1; then
    KUBECTL_CMD="kubectl"
else
    error "Neither 'oc' nor 'kubectl' command found"
fi

RHACS_OPERATOR_NAMESPACE="rhacs-operator"
CLUSTER_CONTEXT="aws-us"

log "Starting cleanup of RHACS operator resources from $CLUSTER_CONTEXT cluster..."

# Switch to aws-us context
log "Switching to $CLUSTER_CONTEXT context..."
if ! $KUBECTL_CMD config use-context "$CLUSTER_CONTEXT" >/dev/null 2>&1; then
    error "Failed to switch to $CLUSTER_CONTEXT context"
fi
log "✓ Switched to $CLUSTER_CONTEXT context"

# Delete SecuredCluster resource
log "Deleting SecuredCluster resources..."
if $KUBECTL_CMD get securedcluster -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    $KUBECTL_CMD delete securedcluster --all -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true || warning "Failed to delete some SecuredCluster resources"
    log "✓ SecuredCluster resources deleted"
else
    log "No SecuredCluster resources found"
fi

# Wait for SecuredCluster to be fully deleted (pods may take time to terminate)
log "Waiting for SecuredCluster resources to be fully removed..."
wait_count=0
max_wait=120
while $KUBECTL_CMD get securedcluster -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; do
    if [ $wait_count -ge $max_wait ]; then
        warning "Timeout waiting for SecuredCluster to be deleted"
        break
    fi
    sleep 2
    wait_count=$((wait_count + 1))
    if [ $((wait_count % 10)) -eq 0 ]; then
        log "  Still waiting for SecuredCluster deletion... ($wait_count/${max_wait}s)"
    fi
done

# Delete operator subscription
log "Deleting RHACS operator subscription..."
if $KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    $KUBECTL_CMD delete subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true || warning "Failed to delete subscription"
    log "✓ Subscription deleted"
else
    log "No subscription found"
fi

# Delete OperatorGroup
log "Deleting OperatorGroup..."
if $KUBECTL_CMD get operatorgroup rhacs-operator-group -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    $KUBECTL_CMD delete operatorgroup rhacs-operator-group -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true || warning "Failed to delete OperatorGroup"
    log "✓ OperatorGroup deleted"
else
    log "No OperatorGroup found"
fi

# Delete CSV (ClusterServiceVersion)
log "Deleting ClusterServiceVersion..."
CSV_NAME=$($KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
if [ -n "$CSV_NAME" ] && [ "$CSV_NAME" != "" ]; then
    $KUBECTL_CMD delete csv "$CSV_NAME" -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true || warning "Failed to delete CSV"
    log "✓ CSV deleted: $CSV_NAME"
else
    log "No CSV found"
fi

# Delete init bundle secrets
log "Deleting init bundle secrets..."
for secret in collector-tls sensor-tls admission-control-tls; do
    if $KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        $KUBECTL_CMD delete secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true || warning "Failed to delete secret $secret"
    fi
done
log "✓ Init bundle secrets deleted"

# Delete all pods in the namespace (they should be cleaned up by the operator, but just in case)
log "Deleting remaining pods in $RHACS_OPERATOR_NAMESPACE namespace..."
if $KUBECTL_CMD get pods -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    $KUBECTL_CMD delete pods --all -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --grace-period=30 || warning "Failed to delete some pods"
    log "✓ Pods deleted"
fi

# Delete the namespace (this will delete all remaining resources)
log "Deleting $RHACS_OPERATOR_NAMESPACE namespace..."
if $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    $KUBECTL_CMD delete namespace "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true || warning "Failed to delete namespace"
    log "✓ Namespace deletion initiated"
    
    # Wait for namespace to be deleted
    log "Waiting for namespace to be fully deleted..."
    wait_count=0
    max_wait=180
    while $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; do
        if [ $wait_count -ge $max_wait ]; then
            warning "Timeout waiting for namespace to be deleted"
            break
        fi
        sleep 2
        wait_count=$((wait_count + 1))
        if [ $((wait_count % 20)) -eq 0 ]; then
            log "  Still waiting for namespace deletion... ($wait_count/${max_wait}s)"
        fi
    done
    log "✓ Namespace deleted"
else
    log "Namespace not found"
fi

log "Cleanup complete. All RHACS operator resources have been removed from $CLUSTER_CONTEXT cluster."
