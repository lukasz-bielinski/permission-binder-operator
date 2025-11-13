#!/bin/bash
# Test 09: Operator Restart Recovery
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 9: Operator Restart Recovery"
echo "-----------------------------------"

# Recreate PermissionBinder first (needed for operator to work)
kubectl apply -f example/permissionbinder/permissionbinder-example.yaml >/dev/null 2>&1
sleep 5

# Count resources before restart
RB_BEFORE_RESTART=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
NS_BEFORE_RESTART=$(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)

# Restart operator
kubectl rollout restart deployment operator-controller-manager -n $NAMESPACE >/dev/null 2>&1
kubectl rollout status deployment operator-controller-manager -n $NAMESPACE --timeout=60s >/dev/null 2>&1
sleep 15

# Count resources after restart
RB_AFTER_RESTART=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
NS_AFTER_RESTART=$(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)

# Verify no duplicates created
if [ "$RB_AFTER_RESTART" -eq "$RB_BEFORE_RESTART" ] && [ "$NS_AFTER_RESTART" -eq "$NS_BEFORE_RESTART" ]; then
    pass_test "Operator recovered without creating duplicates"
    info_log "Resources stable: $RB_AFTER_RESTART RoleBindings, $NS_AFTER_RESTART Namespaces"
else
    fail_test "Resource count changed (RB: $RB_BEFORE_RESTART→$RB_AFTER_RESTART, NS: $NS_BEFORE_RESTART→$NS_AFTER_RESTART)"
fi

echo ""

# ============================================================================
