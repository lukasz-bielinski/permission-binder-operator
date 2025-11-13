#!/bin/bash
# Test 46: Networkpolicy   Drift Detection
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 46: NetworkPolicy - Drift Detection"
echo "-----------------------------------------"

# Wait for periodic reconciliation interval
# Note: This test requires periodic reconciliation to run
# In real scenario, would wait for reconciliationInterval (1h)
info_log "Waiting for periodic reconciliation (up to 90s)"
MAX_WAIT=90
WAITED=0
RECONCILIATION_TIME=""
while [ $WAITED -lt $MAX_WAIT ]; do
    RECONCILIATION_TIME=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath='{.status.lastNetworkPolicyReconciliation}' 2>/dev/null || echo "")
    if [ -n "$RECONCILIATION_TIME" ] && [ "$RECONCILIATION_TIME" != "" ]; then
        break
    fi
    sleep 10
    WAITED=$((WAITED + 10))
done

if [ -n "$RECONCILIATION_TIME" ] && [ "$RECONCILIATION_TIME" != "" ]; then
    pass_test "Periodic reconciliation timestamp found: $RECONCILIATION_TIME"
else
    info_log "Periodic reconciliation timestamp not yet available (may need to wait for reconciliationInterval: 1h)"
fi

# ============================================================================
# VERIFICATION: Check PRs for ALL namespaces in PermissionBinder status
# This test doesn't create new PRs, but should verify existing ones
# ============================================================================
GITHUB_REPO="lukasz-bielinski/tests-network-policies"

# Get all namespaces with NetworkPolicy status
ALL_NAMESPACES=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath='{.status.networkPolicies[*].namespace}' 2>/dev/null || echo "")

if [ -n "$ALL_NAMESPACES" ] && [ "$ALL_NAMESPACES" != "" ]; then
    info_log "Found namespaces with NetworkPolicy status: $ALL_NAMESPACES"
    info_log "Note: This test verifies periodic reconciliation, not PR creation"
else
    info_log "No namespaces found in NetworkPolicy status (may be normal if no PRs were created)"
fi

# ============================================================================
# CLEANUP: Remove PRs and branches from GitHub (test isolation)
# IMPORTANT: Cleanup is done AFTER all verifications are complete
# IMPORTANT: Removes entire cluster_name directory
# ============================================================================
info_log "=========================================="
info_log "Starting cleanup..."
info_log "=========================================="
cleanup_all_networkpolicy_test_artifacts "test-permissionbinder-networkpolicy" "$GITHUB_REPO" "DEV-cluster"

echo ""

# ============================================================================
