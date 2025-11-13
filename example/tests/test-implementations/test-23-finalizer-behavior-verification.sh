#!/bin/bash
# Test 23: Finalizer Behavior Verification
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 23: Finalizer Behavior Verification"
echo "------------------------------------------"

# Check if PermissionBinder exists (may have been deleted in Test 8)
if kubectl_retry kubectl get permissionbinder permissionbinder-example -n $NAMESPACE >/dev/null 2>&1; then
    # Verify finalizer is present
    FINALIZER=$(kubectl_retry kubectl get permissionbinder permissionbinder-example -n $NAMESPACE -o jsonpath='{.metadata.finalizers[0]}' 2>/dev/null)
    if [ "$FINALIZER" == "permission-binder.io/finalizer" ]; then
        pass_test "Finalizer is present on PermissionBinder"
    else
        fail_test "Finalizer not found: $FINALIZER"
    fi
else
    # PermissionBinder doesn't exist (deleted in Test 8), which is expected
    pass_test "Finalizer behavior verified in Test 8 (PermissionBinder deleted)"
    info_log "PermissionBinder was deleted in Test 8 - finalizer cleanup tested there"
fi

info_log "Finalizer ensures proper cleanup sequence (tested in Test 8)"

echo ""

# ============================================================================
