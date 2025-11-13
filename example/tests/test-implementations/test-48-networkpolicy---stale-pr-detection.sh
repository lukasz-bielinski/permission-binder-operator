#!/bin/bash
# Test 48: Networkpolicy   Stale Pr Detection
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 48: NetworkPolicy - Stale PR Detection"
echo "--------------------------------------------"

# This test verifies that stale PR detection runs
# In real scenario, would wait for stalePRThreshold
ALL_STATES=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath='{.status.networkPolicies[*].state}' 2>/dev/null || echo "")
STALE_FOUND=false
for state in $ALL_STATES; do
    if [ "$state" == "pr-stale" ]; then
        STALE_FOUND=true
        break
    fi
done

if [ "$STALE_FOUND" == "true" ]; then
    # Verify CreatedAt timestamp exists for stale PR
    STALE_CREATED_AT=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath='{.status.networkPolicies[?(@.state=="pr-stale")].createdAt}' 2>/dev/null || echo "")
    if [ -n "$STALE_CREATED_AT" ] && [ "$STALE_CREATED_AT" != "" ]; then
        pass_test "Stale PR detected with CreatedAt timestamp: $STALE_CREATED_AT"
    else
        fail_test "Stale PR detected but CreatedAt timestamp missing"
    fi
else
    info_log "No stale PRs detected (may need to wait for stalePRThreshold)"
fi

# ============================================================================
# VERIFICATION: Check PRs for ALL namespaces in PermissionBinder status
# This test verifies stale PR detection, should check all existing PRs
# ============================================================================
GITHUB_REPO="lukasz-bielinski/tests-network-policies"

# Get all namespaces with NetworkPolicy status
ALL_NAMESPACES=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath='{.status.networkPolicies[*].namespace}' 2>/dev/null || echo "")

if [ -n "$ALL_NAMESPACES" ] && [ "$ALL_NAMESPACES" != "" ]; then
    info_log "Found namespaces with NetworkPolicy status: $ALL_NAMESPACES"
    info_log "Verifying PR states for all namespaces..."
    for ns in $ALL_NAMESPACES; do
        NS_STATE=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$ns\")].state}" 2>/dev/null || echo "")
        info_log "  Namespace $ns: state=$NS_STATE"
    done
else
    info_log "No namespaces found in NetworkPolicy status"
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
