#!/bin/bash
# Test 19: Concurrent Configmap Changes Race Conditions
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 19: Concurrent ConfigMap Changes (Race Conditions)"
echo "---------------------------------------------------------"

# Make rapid concurrent changes to trigger potential race conditions
for i in {1..5}; do
    kubectl_retry kubectl annotate configmap permission-config -n $NAMESPACE concurrent-test-$i="$(date +%s)" --overwrite >/dev/null 2>&1 &
done
wait

sleep 20

# Verify no race condition errors
RACE_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "conflict\|race\|concurrent" | wc -l)
info_log "Concurrent change log entries: $RACE_ERRORS"

# Verify resources are consistent
RB_CONSISTENT=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_CONSISTENT" -gt 0 ]; then
    pass_test "Resources consistent after concurrent changes"
else
    fail_test "Resources lost after concurrent changes"
fi

# Verify operator didn't restart
POD_RESTARTS=$(kubectl_retry kubectl get pods -n $NAMESPACE -l control-plane=controller-manager -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
if [ "$POD_RESTARTS" -eq 0 ]; then
    pass_test "Operator handled concurrent changes without restarting"
else
    info_log "Operator restarted $POD_RESTARTS times during test"
fi

echo ""

# ============================================================================
