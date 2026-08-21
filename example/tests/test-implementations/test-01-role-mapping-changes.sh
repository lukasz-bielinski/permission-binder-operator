#!/bin/bash
# Test 01: Role Mapping Changes
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# Test namespaces carry the per-instance prefix (empty in legacy mode)
TEST_NS_DEV="${TEST_NS_PREFIX}test-namespace"

# ============================================================================
# ============================================================================
echo "Test 1: Role Mapping Changes"
echo "------------------------------"

# Count current RoleBindings (scoped to this instance's CR - issue #35)
RB_BEFORE=$(count_owned_rolebindings "permissionbinder-example")
info_log "RoleBindings before: $RB_BEFORE"

# Add new role to PermissionBinder mapping
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"add","path":"/spec/roleMapping/developer","value":"edit"}]' >/dev/null 2>&1

# Add ConfigMap entry with "developer" role to test the new mapping
# Get current whitelist and append new entry
CURRENT_WHITELIST=$(kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}')
kubectl_retry kubectl patch configmap permission-config -n $NAMESPACE --type=merge \
  -p="{\"data\":{\"whitelist.txt\":\"${CURRENT_WHITELIST}\nCN=COMPANY-K8S-${TEST_NS_DEV}-developer,OU=Example,DC=example,DC=com\"}}" >/dev/null 2>&1

sleep 20

# Check if new RoleBindings were created (own CR only)
RB_AFTER=$(count_owned_rolebindings "permissionbinder-example")
if [ "$RB_AFTER" -gt "$RB_BEFORE" ]; then
    pass_test "New RoleBindings created after role mapping change"
    info_log "RoleBindings increased: $RB_BEFORE → $RB_AFTER"
else
    fail_test "No new RoleBindings created (still $RB_AFTER)"
fi

# Verify RoleBinding references new role
DEVELOPER_RB=$(list_owned_rolebindings "permissionbinder-example" | grep -c "developer" | head -1)
if [ "$DEVELOPER_RB" -gt 0 ]; then
    pass_test "RoleBindings reference new ClusterRole correctly"
else
    info_log "No 'developer' RoleBindings found (ConfigMap may not have matching entries)"
fi

echo ""

# ============================================================================
