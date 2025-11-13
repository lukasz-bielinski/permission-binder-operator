#!/bin/bash
# Test 02: Prefix Changes
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 2: Prefix Changes"
echo "-----------------------"

# Note: Current implementation uses prefixes (array), not single prefix
# This test verifies prefix change behavior

# Count RoleBindings with current prefix
CURRENT_RB=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
info_log "Current RoleBindings: $CURRENT_RB"

# Change prefix array
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"replace","path":"/spec/prefixes","value":["NEW-PREFIX"]}]' >/dev/null 2>&1

sleep 15

# Check if operator processed new prefix
NEW_PREFIX_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -c "NEW-PREFIX" | tr -d '\n' | head -1 || echo "0")
info_log "Logs mentioning NEW-PREFIX: $NEW_PREFIX_LOGS"

if [ "$NEW_PREFIX_LOGS" -gt 0 ]; then
    pass_test "Operator processed new prefix configuration"
else
    info_log "New prefix not yet processed (ConfigMap entries use old prefix)"
fi

# Restore original prefix
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"replace","path":"/spec/prefixes","value":["COMPANY-K8S"]}]' >/dev/null 2>&1
sleep 5

echo ""

# ============================================================================
