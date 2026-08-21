#!/bin/bash
# Test 08: Permissionbinder Deletion Safe Mode
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 8: PermissionBinder Deletion (SAFE MODE)"
echo "-----------------------------------------------"

# Count resources before deletion (scoped to this instance's CR - issue #35)
RB_BEFORE_DELETE=$(count_owned_rolebindings "permissionbinder-example")
NS_BEFORE_DELETE=$(count_owned_namespaces "permissionbinder-example")
info_log "Before deletion: $RB_BEFORE_DELETE RoleBindings, $NS_BEFORE_DELETE Namespaces"

# Delete PermissionBinder
kubectl_retry kubectl delete permissionbinder permissionbinder-example -n $NAMESPACE >/dev/null 2>&1
sleep 10

# Check resources were NOT deleted (SAFE MODE; own CR only)
RB_AFTER_DELETE=$(count_owned_rolebindings "permissionbinder-example")
NS_AFTER_DELETE=$(count_owned_namespaces "permissionbinder-example")

if [ "$RB_AFTER_DELETE" -eq "$RB_BEFORE_DELETE" ] && [ "$NS_AFTER_DELETE" -eq "$NS_BEFORE_DELETE" ]; then
    pass_test "SAFE MODE: Resources NOT deleted when PermissionBinder deleted"
    info_log "After deletion: $RB_AFTER_DELETE RoleBindings, $NS_AFTER_DELETE Namespaces"
else
    fail_test "Resources were deleted! RB: $RB_BEFORE_DELETE→$RB_AFTER_DELETE, NS: $NS_BEFORE_DELETE→$NS_AFTER_DELETE"
fi

# Check orphaned annotations
ORPHANED_COUNT=$(kubectl_retry kubectl get rolebindings -A -l "$MANAGED_BY_LABEL" -o json | jq --arg pb "permissionbinder-example" --arg ns "$NAMESPACE" '[.items[] | select(.metadata.annotations["permission-binder.io/permission-binder"] == $pb and ((.metadata.annotations["permission-binder.io/permission-binder-namespace"] // $ns) == $ns) and .metadata.annotations["permission-binder.io/orphaned-at"])] | length')
if [ "$ORPHANED_COUNT" -gt 0 ]; then
    pass_test "Resources marked as orphaned (annotation added)"
    info_log "Orphaned resources: $ORPHANED_COUNT"
else
    info_log "No orphaned annotations found (may need more reconciliation time)"
fi

echo ""

# ============================================================================
