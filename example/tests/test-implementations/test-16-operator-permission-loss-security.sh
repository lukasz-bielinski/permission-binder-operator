#!/bin/bash
# Test 16: Operator Permission Loss Security
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 16: Operator Permission Loss (Security)"
echo "----------------------------------------------"

# This test temporarily removes RBAC permissions to verify error handling
# Note: Be careful with this test as it affects operator functionality

# Remove a specific permission (list rolebindings)
kubectl_retry kubectl get clusterrole permission-binder-operator-manager-role -o json > /tmp/clusterrole-backup.json
kubectl_retry kubectl get clusterrole permission-binder-operator-manager-role -o json | \
  jq 'del(.rules[] | select(.resources[] == "rolebindings"))' | \
  kubectl apply -f - >/dev/null 2>&1

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-rbac-loss="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check for permission errors in logs
PERMISSION_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "forbidden\|unauthorized\|permission denied" | wc -l)

if [ "$PERMISSION_ERRORS" -gt 0 ]; then
    pass_test "Operator logged permission errors correctly"
    info_log "Permission error log entries: $PERMISSION_ERRORS"
else
    info_log "No permission errors detected (RBAC may still be valid)"
fi

# Restore permissions
kubectl apply -f /tmp/clusterrole-backup.json >/dev/null 2>&1
rm -f /tmp/clusterrole-backup.json
sleep 5

# Verify operator recovered
DEPLOYMENT_READY=$(kubectl_retry kubectl get deployment operator-controller-manager -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator recovered after RBAC restoration"
else
    fail_test "Operator not running after RBAC restoration: $POD_STATUS"
fi

echo ""

# ============================================================================
