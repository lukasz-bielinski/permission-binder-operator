#!/bin/bash
# Test 10: Conflict Handling
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 10: Conflict Handling"
echo "----------------------------"

# Add duplicate entry to ConfigMap (duplicates the baseline project1 entry,
# which carries $TEST_NS_PREFIX under per-instance isolation)
WHITELIST_DUP="${RUN_DIR:-/tmp}/whitelist-dup.txt"
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > "$WHITELIST_DUP"
echo "CN=COMPANY-K8S-${TEST_NS_PREFIX}project1-engineer,OU=Test,DC=example,DC=com" >> "$WHITELIST_DUP"
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt="$WHITELIST_DUP" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f "$WHITELIST_DUP"

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-conflict="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 15

# Verify no crash errors in logs
CRASH_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "panic\|fatal\|crash" | wc -l)
if [ "$CRASH_ERRORS" -eq 0 ]; then
    pass_test "Operator handled duplicate entries gracefully (no panic/crash)"
else
    fail_test "Operator encountered errors: $CRASH_ERRORS panic/crash logs"
fi

# Verify RoleBindings still managed (own CR only - issue #35 scoping)
RB_CONFLICT=$(count_owned_rolebindings "permissionbinder-example")
if [ "$RB_CONFLICT" -gt 0 ]; then
    pass_test "RoleBindings still managed despite duplicates"
else
    fail_test "RoleBindings lost due to conflict"
fi

echo ""

# ============================================================================
