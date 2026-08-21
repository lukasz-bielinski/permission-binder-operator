#!/bin/bash
# Test 04: Configmap Changes   Addition
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# Test namespaces carry the per-instance prefix (empty in legacy mode)
TEST4_NS="${TEST_NS_PREFIX}test4-new-namespace"
WHITELIST_ADD="${RUN_DIR:-/tmp}/whitelist-add.txt"

# ============================================================================
# ============================================================================
echo "Test 4: ConfigMap Changes - Addition"
echo "-------------------------------------"

# Add new LDAP DN entry to whitelist.txt
NEW_ENTRY="CN=COMPANY-K8S-${TEST4_NS}-admin,OU=TestOU,DC=example,DC=com"
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > "$WHITELIST_ADD"
echo "$NEW_ENTRY" >> "$WHITELIST_ADD"
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt="$WHITELIST_ADD" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f "$WHITELIST_ADD"

# Force reconciliation
kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-addition="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 30

# Check namespace created
NS_EXISTS=$(kubectl_retry kubectl get namespace "$TEST4_NS" 2>/dev/null | wc -l)
if [ "$NS_EXISTS" -gt 0 ]; then
    pass_test "New namespace created from ConfigMap entry"
else
    fail_test "Namespace not created"
fi

# Check RoleBinding created
RB_EXISTS=$(kubectl_retry kubectl get rolebinding "${TEST4_NS}-admin" -n "$TEST4_NS" 2>/dev/null | wc -l)
if [ "$RB_EXISTS" -gt 0 ]; then
    pass_test "RoleBinding created for new ConfigMap entry"
else
    fail_test "RoleBinding not created"
fi

# Verify annotations (managed-by value is per-instance under MANAGED_BY_VALUE)
ANNOTATIONS=$(kubectl_retry kubectl get rolebinding "${TEST4_NS}-admin" -n "$TEST4_NS" -o jsonpath='{.metadata.annotations}' 2>/dev/null | jq -e '."permission-binder.io/managed-by"' 2>/dev/null)
if [ "$ANNOTATIONS" == "\"${MANAGED_BY_VALUE}\"" ]; then
    pass_test "RoleBinding has correct annotations"
else
    info_log "RoleBinding annotations may be incorrect"
fi

echo ""

# ============================================================================
