#!/bin/bash
# Test 20: Configmap Corruption Handling
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 20: ConfigMap Corruption Handling"
echo "----------------------------------------"

# Test with various malformed entries
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-corrupt.txt
echo "CN=COMPANY-K8S-incomplete" >> /tmp/whitelist-corrupt.txt  # Missing parts
echo "CN=" >> /tmp/whitelist-corrupt.txt  # Empty CN
echo "$(python3 -c 'print("A"*300)')" >> /tmp/whitelist-corrupt.txt  # Too long
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-corrupt.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-corrupt.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-corrupt="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 15

# Verify operator didn't crash
POD_RESTARTS=$(kubectl_retry kubectl get pods -n $NAMESPACE -l control-plane=controller-manager -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
if [ "$POD_RESTARTS" -eq 0 ]; then
    pass_test "Operator handled corrupted ConfigMap without crashing"
else
    fail_test "Operator restarted $POD_RESTARTS times due to corruption"
fi

# Verify error logging
CORRUPTION_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "error\|invalid" | wc -l)
info_log "Corruption handling log entries: $CORRUPTION_LOGS"

echo ""

# ============================================================================
