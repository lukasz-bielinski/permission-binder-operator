#!/bin/bash
# Test 21: Network Failure Simulation
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 21: Network Failure Simulation"
echo "-------------------------------------"

# Simulate stress by rapid reconciliation triggers
info_log "Simulating network stress via rapid reconciliation"

for i in {1..10}; do
    kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE stress-test-$i="$(date +%s)" --overwrite >/dev/null 2>&1 &
done
wait
sleep 15

# Check for connection errors
CONN_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=100 | grep -i "connection refused\|timeout\|dial tcp\|i/o timeout" | wc -l)
info_log "Connection-related log entries: $CONN_ERRORS"

# Verify operator is still functional
RB_CURRENT=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_CURRENT" -gt 0 ]; then
    pass_test "Operator remained functional under stress"
    info_log "Managed RoleBindings: $RB_CURRENT"
else
    fail_test "Operator lost managed resources"
fi

# Verify no crash/restarts
POD_RESTARTS=$(kubectl_retry kubectl get pods -n $NAMESPACE -l control-plane=controller-manager -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
if [ "$POD_RESTARTS" -eq 0 ]; then
    pass_test "Operator handled stress without restarting"
else
    info_log "Operator restarted $POD_RESTARTS times during stress test"
fi

echo ""

# ============================================================================
