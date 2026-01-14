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

# Delete SecuredCluster resource (force delete)
log "Force deleting SecuredCluster resources..."
if $KUBECTL_CMD get securedcluster -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    $KUBECTL_CMD delete securedcluster --all -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --force --grace-period=0 || warning "Failed to delete some SecuredCluster resources"
    log "✓ SecuredCluster resources force deleted"
else
    log "No SecuredCluster resources found"
fi

# Delete all deployments, daemonsets, statefulsets (force delete)
log "Force deleting all workloads..."
$KUBECTL_CMD delete deployment --all -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --force --grace-period=0 2>/dev/null || true
$KUBECTL_CMD delete daemonset --all -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --force --grace-period=0 2>/dev/null || true
$KUBECTL_CMD delete statefulset --all -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --force --grace-period=0 2>/dev/null || true
log "✓ Workloads force deleted"

# Delete all pods (force delete)
log "Force deleting all pods in $RHACS_OPERATOR_NAMESPACE namespace..."
$KUBECTL_CMD delete pods --all -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --force --grace-period=0 2>/dev/null || true
log "✓ Pods force deleted"

# Delete operator subscription (force delete)
log "Force deleting RHACS operator subscription..."
if $KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    $KUBECTL_CMD delete subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --force --grace-period=0 || warning "Failed to delete subscription"
    log "✓ Subscription force deleted"
else
    log "No subscription found"
fi

# Delete OperatorGroup (force delete)
log "Force deleting OperatorGroup..."
if $KUBECTL_CMD get operatorgroup rhacs-operator-group -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    $KUBECTL_CMD delete operatorgroup rhacs-operator-group -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --force --grace-period=0 || warning "Failed to delete OperatorGroup"
    log "✓ OperatorGroup force deleted"
else
    log "No OperatorGroup found"
fi

# Delete CSV (ClusterServiceVersion) (force delete)
log "Force deleting ClusterServiceVersion..."
CSV_NAME=$($KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
if [ -n "$CSV_NAME" ] && [ "$CSV_NAME" != "" ]; then
    $KUBECTL_CMD delete csv "$CSV_NAME" -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --force --grace-period=0 || warning "Failed to delete CSV"
    log "✓ CSV force deleted: $CSV_NAME"
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

# Delete all remaining resources (services, configmaps, etc.)
log "Deleting all remaining resources..."
$KUBECTL_CMD delete all --all -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --force --grace-period=0 2>/dev/null || true
$KUBECTL_CMD delete configmap --all -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --force --grace-period=0 2>/dev/null || true
$KUBECTL_CMD delete service --all -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --force --grace-period=0 2>/dev/null || true
log "✓ Remaining resources deleted"

# Force delete the namespace (this will delete all remaining resources)
log "Force deleting $RHACS_OPERATOR_NAMESPACE namespace..."
if $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    # First, try to remove finalizers from all resources in the namespace
    log "Removing finalizers from resources in namespace..."
    
    # Remove finalizers from SecuredCluster
    $KUBECTL_CMD patch securedcluster --all -n "$RHACS_OPERATOR_NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    
    # Remove finalizers from CSV
    for csv in $($KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" -o name 2>/dev/null || echo ""); do
        if [ -n "$csv" ]; then
            $KUBECTL_CMD patch "$csv" -n "$RHACS_OPERATOR_NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        fi
    done
    
    # Force delete namespace
    $KUBECTL_CMD delete namespace "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --force --grace-period=0 || warning "Failed to delete namespace"
    log "✓ Namespace force deletion initiated"
    
    # Wait briefly and check if namespace is gone
    sleep 5
    if $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        # If still exists, try to patch finalizers
        log "Namespace still exists, removing finalizers..."
        $KUBECTL_CMD patch namespace "$RHACS_OPERATOR_NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        sleep 2
    fi
    
    if ! $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        log "✓ Namespace deleted"
    else
        warning "Namespace may still exist. You may need to manually remove finalizers."
    fi
else
    log "Namespace not found"
fi

log "Cleanup complete. All RHACS operator resources have been removed from $CLUSTER_CONTEXT cluster."
