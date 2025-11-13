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

# Add duplicate entry to ConfigMap
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-dup.txt
echo "CN=COMPANY-K8S-project1-engineer,OU=Test,DC=example,DC=com" >> /tmp/whitelist-dup.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-dup.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-dup.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-conflict="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 15

# Verify no crash errors in logs
CRASH_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "panic\|fatal\|crash" | wc -l)
if [ "$CRASH_ERRORS" -eq 0 ]; then
    pass_test "Operator handled duplicate entries gracefully (no panic/crash)"
else
    fail_test "Operator encountered errors: $CRASH_ERRORS panic/crash logs"
fi

# Verify RoleBindings still managed
RB_CONFLICT=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_CONFLICT" -gt 0 ]; then
    pass_test "RoleBindings still managed despite duplicates"
else
    fail_test "RoleBindings lost due to conflict"
fi

echo ""

# ============================================================================
