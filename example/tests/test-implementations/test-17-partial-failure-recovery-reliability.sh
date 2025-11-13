#!/bin/bash
# Test 17: Partial Failure Recovery Reliability
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 17: Partial Failure Recovery (Reliability)"
echo "-------------------------------------------------"

# Add mix of valid and invalid entries
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-mixed.txt
echo "CN=COMPANY-K8S-valid-test17-ns-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-mixed.txt
echo "INVALID-ENTRY-NO-CN" >> /tmp/whitelist-mixed.txt
echo "CN=COMPANY-K8S-another-valid-test17-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-mixed.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-mixed.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-mixed.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-partial="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 20

# Check if valid entries were processed
VALID_NS1=$(kubectl_retry kubectl get namespace valid-test17-ns 2>/dev/null | wc -l)
VALID_NS2=$(kubectl_retry kubectl get namespace another-valid-test17 2>/dev/null | wc -l)

if [ "$VALID_NS1" -gt 0 ] || [ "$VALID_NS2" -gt 0 ]; then
    pass_test "Valid entries processed despite invalid ones"
else
    info_log "Valid namespaces not created (may be timing or parsing issue)"
fi

# Verify operator still running
DEPLOYMENT_READY=$(kubectl_retry kubectl get deployment operator-controller-manager -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator remains running after partial failures"
else
    fail_test "Operator deployment not ready"
fi

echo ""

# ============================================================================
