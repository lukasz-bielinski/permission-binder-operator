#!/bin/bash
# Test 06: Role Removal From Mapping
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 6: Role Removal from Mapping"
echo "-----------------------------------"

# Add temporary role
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"add","path":"/spec/roleMapping/temp-test-role","value":"view"}]' >/dev/null 2>&1

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-temp-add="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check if temp role RoleBindings were created
TEMP_RB_COUNT=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '[.items[] | select(.metadata.name | contains("temp-test-role"))] | length')
info_log "Temp role RoleBindings created: $TEMP_RB_COUNT"

# Remove temp role
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"remove","path":"/spec/roleMapping/temp-test-role"}]' >/dev/null 2>&1

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-temp-remove="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check temp role RoleBindings were removed
TEMP_RB_AFTER=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '[.items[] | select(.metadata.name | contains("temp-test-role"))] | length')
if [ "$TEMP_RB_AFTER" -eq 0 ]; then
    pass_test "RoleBindings removed when role deleted from mapping"
else
    fail_test "RoleBindings not removed: still $TEMP_RB_AFTER temp-test-role RoleBindings"
fi

echo ""

# ============================================================================
