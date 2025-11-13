#!/bin/bash
# Test 14: Orphaned Resources Adoption
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 14: Orphaned Resources Adoption"
echo "--------------------------------------"

# Check for orphaned resources (from Test 8)
ORPHANED_BEFORE=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '[.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])] | length')
info_log "Orphaned resources before reconciliation: $ORPHANED_BEFORE"

# Force reconciliation
kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-adoption="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 30

# Check adoption logs
ADOPTION_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=100 | grep -v "^I" | grep -c "Adopted\|adoption" 2>/dev/null | tr -d '\n' | head -1 || echo "0")
info_log "Adoption-related log entries: $ADOPTION_LOGS"

# Check if orphaned resources decreased
ORPHANED_AFTER=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '[.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])] | length' | tr -d '\n')

if [ "$ORPHANED_AFTER" -lt "$ORPHANED_BEFORE" ] || [ "$ADOPTION_LOGS" -gt 0 ]; then
    pass_test "Automatic adoption of orphaned resources"
    info_log "Orphaned resources: $ORPHANED_BEFORE → $ORPHANED_AFTER"
else
    info_log "No adoption detected (resources: $ORPHANED_BEFORE → $ORPHANED_AFTER)"
fi

echo ""

# ============================================================================
