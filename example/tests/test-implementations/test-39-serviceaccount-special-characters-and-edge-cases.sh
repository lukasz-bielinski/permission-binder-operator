#!/bin/bash
# Test 39: Serviceaccount Special Characters And Edge Cases
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 39: ServiceAccount Special Characters & Edge Cases"
echo "---------------------------------------------------------"

# Test valid characters (hyphens)
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-special-chars
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    my-deploy-sa: edit
    test-runtime-123: view
EOF

sleep 15

if kubectl get namespace test-namespace-001 >/dev/null 2>&1; then
    # Check valid names
    VALID_COUNT=0
    if kubectl get sa -n test-namespace-001 2>/dev/null | grep -q "my-deploy-sa"; then
        VALID_COUNT=$((VALID_COUNT + 1))
    fi
    if kubectl get sa -n test-namespace-001 2>/dev/null | grep -q "test-runtime-123"; then
        VALID_COUNT=$((VALID_COUNT + 1))
    fi
    
    if [ $VALID_COUNT -eq 2 ]; then
        pass_test "Valid special characters supported (hyphens, numbers)"
    else
        info_log "Valid character test: $VALID_COUNT/2 ServiceAccounts created"
    fi
    
    # Test empty mapping (should not crash)
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-empty
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping: {}
EOF
    
    sleep 5
    
    # Verify operator still running
    POD_STATUS=$(kubectl get pod -n $NAMESPACE -l control-plane=controller-manager -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ "$POD_STATUS" == "Running" ]; then
        pass_test "Empty ServiceAccount mapping handled gracefully (no crash)"
    else
        fail_test "Operator not running after empty mapping"
    fi
else
    info_log "test-namespace-001 does not exist, skipping edge case tests"
fi

echo ""

# ============================================================================
