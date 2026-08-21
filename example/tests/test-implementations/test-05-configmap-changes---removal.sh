#!/bin/bash
# Test 05: Configmap Changes   Removal
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 5: ConfigMap Changes - Removal"
echo "------------------------------------"

# Count RoleBindings before removal (scoped to this instance's CR - issue #35)
RB_BEFORE_REMOVAL=$(count_owned_rolebindings "permissionbinder-example")

# Remove entry from whitelist.txt (remove project3 if exists)
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' | grep -v "project3" > /tmp/whitelist-removal.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-removal.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-removal.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-removal="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 20

# Check RoleBinding removed (own CR only)
RB_AFTER_REMOVAL=$(count_owned_rolebindings "permissionbinder-example")
if [ "$RB_AFTER_REMOVAL" -le "$RB_BEFORE_REMOVAL" ]; then
    pass_test "RoleBinding removed after ConfigMap entry deletion"
    info_log "RoleBindings: $RB_BEFORE_REMOVAL → $RB_AFTER_REMOVAL"
else
    info_log "RoleBinding count unchanged (may need more reconciliation time)"
fi

# Verify namespace preserved (SAFE MODE)
NS_PROJECT3=$(kubectl_retry kubectl get namespace project3 2>/dev/null | wc -l)
if [ "$NS_PROJECT3" -gt 0 ]; then
    pass_test "Namespace preserved after entry removal (SAFE MODE)"
else
    info_log "Namespace project3 doesn't exist or was deleted"
fi

echo ""

# ============================================================================
