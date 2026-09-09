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

# Test namespace carries the per-instance prefix (empty in legacy mode)
TEST2_NS="${TEST_NS_PREFIX}prefix-test-02"
WHITELIST_PREFIX="${RUN_DIR:-/tmp}/whitelist-prefix.txt"

# Count RoleBindings with current prefix
CURRENT_RB=$(kubectl_retry kubectl get rolebindings -A -l "$MANAGED_BY_LABEL" --no-headers | wc -l)
info_log "Current RoleBindings: $CURRENT_RB"

# Change prefix array
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"replace","path":"/spec/prefixes","value":["NEW-PREFIX"]}]' >/dev/null 2>&1

e2e_sleep 15

# Check if operator processed new prefix
NEW_PREFIX_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -c "NEW-PREFIX" | tr -d '\n' | head -1 || echo "0")
info_log "Logs mentioning NEW-PREFIX: $NEW_PREFIX_LOGS"

if [ "$NEW_PREFIX_LOGS" -gt 0 ]; then
    pass_test "Operator processed new prefix configuration"
else
    fail_test "New prefix not processed (no NEW-PREFIX in operator logs)"
fi

# Real outcome assertion (issue #92): an entry under the NEW prefix must
# produce its namespace + RoleBinding; under the old prefix configuration it
# would be rejected, so this fails unless the prefix change took effect.
NEW_ENTRY="CN=NEW-PREFIX-${TEST2_NS}-admin,OU=TestOU,DC=example,DC=com"
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > "$WHITELIST_PREFIX"
echo "$NEW_ENTRY" >> "$WHITELIST_PREFIX"
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt="$WHITELIST_PREFIX" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f "$WHITELIST_PREFIX"

# Force reconciliation
kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-prefix-change="$(date +%s)" --overwrite >/dev/null 2>&1
e2e_sleep 30

# Check namespace created from the NEW-PREFIX entry
NS_EXISTS=$(kubectl_retry kubectl get namespace "$TEST2_NS" 2>/dev/null | wc -l)
if [ "$NS_EXISTS" -gt 0 ]; then
    pass_test "Namespace created for entry with new prefix"
else
    fail_test "Namespace not created for new-prefix entry"
fi

# Check RoleBinding created for the new-prefix entry (owned by this instance's CR)
RB_CREATED=$(list_owned_rolebindings "permissionbinder-example" | grep -c "$TEST2_NS $TEST2_NS-admin" | head -1)
if [ "$RB_CREATED" -gt 0 ]; then
    pass_test "RoleBinding created for entry with new prefix"
else
    fail_test "RoleBinding not created for new-prefix entry"
fi

# Restore original prefix
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"replace","path":"/spec/prefixes","value":["COMPANY-K8S"]}]' >/dev/null 2>&1
# Drop the new-prefix entry again so the restore does not re-remove it on
# every subsequent reconcile
CURRENT_WHITELIST=$(kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' 2>/dev/null)
printf '%s\n' "$CURRENT_WHITELIST" | grep -v "NEW-PREFIX" > "$WHITELIST_PREFIX" || true
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt="$WHITELIST_PREFIX" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f "$WHITELIST_PREFIX"
e2e_sleep 5

echo ""

# ============================================================================
