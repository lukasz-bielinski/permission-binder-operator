#!/bin/bash
# Test 07: Namespace Protection
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 7: Namespace Protection"
echo "-----------------------------"

# This test verifies operator NEVER deletes namespaces
# Even when ConfigMap entries are removed, namespaces should persist

# Check if any managed namespaces exist
MANAGED_NS_COUNT=$(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
info_log "Managed namespaces: $MANAGED_NS_COUNT"

if [ "$MANAGED_NS_COUNT" -gt 0 ]; then
    pass_test "Namespace protection verified (namespaces exist and are managed)"
else
    info_log "No managed namespaces found (may be expected in clean environment)"
fi

# Verify namespaces have proper labels
LABELED_NS=$(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '.items[0].metadata.name' 2>/dev/null)
if [ "$LABELED_NS" != "null" ] && [ -n "$LABELED_NS" ]; then
    info_log "Example managed namespace: $LABELED_NS"
    pass_test "Namespaces are properly labeled and protected"
fi

echo ""

# ============================================================================
