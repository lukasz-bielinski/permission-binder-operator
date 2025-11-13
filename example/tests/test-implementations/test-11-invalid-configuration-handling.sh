#!/bin/bash
# Test 11: Invalid Configuration Handling
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 11: Invalid Configuration Handling"
echo "-----------------------------------------"

# Add invalid LDAP DN to whitelist.txt (missing CN=)
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-invalid.txt
echo "INVALID-FORMAT-no-cn-prefix,OU=Test,DC=example,DC=com" >> /tmp/whitelist-invalid.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-invalid.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-invalid.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-invalid="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check operator logs for error handling
ERROR_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "error\|invalid" | wc -l)
info_log "Error/invalid log entries: $ERROR_LOGS"

# Verify valid entries still processed (at least 1 valid RoleBinding exists)
VALID_RB_COUNT=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
info_log "Current RoleBindings: $VALID_RB_COUNT"
if [ "$VALID_RB_COUNT" -ge 1 ]; then
    pass_test "Valid entries processed despite invalid ones"
else
    fail_test "No valid RoleBindings found (invalid entry may have broken processing)"
fi

# Verify operator still running
DEPLOYMENT_READY=$(kubectl_retry kubectl get deployment operator-controller-manager -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator remains running after invalid configuration"
else
    fail_test "Operator deployment not ready"
fi

echo ""

# ============================================================================
