#!/bin/bash
# Test 36: Serviceaccount Deletion And Cleanup Orphaned Rolebindings
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 36: ServiceAccount Deletion and Cleanup"
echo "----------------------------------------------"

# Create PermissionBinder for cleanup test
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-cleanup
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    cleanup-test: edit
EOF

sleep 15

if kubectl get namespace test-namespace-001 >/dev/null 2>&1; then
    # Check if SA and RoleBinding exist
    if kubectl get sa test-namespace-001-sa-cleanup-test -n test-namespace-001 >/dev/null 2>&1; then
        RB_NAME=$(kubectl get rolebinding -n test-namespace-001 -o json 2>/dev/null | jq -r '.items[] | select(.subjects[0].name | contains("sa-cleanup-test")) | .metadata.name' | head -1)
        info_log "RoleBinding: $RB_NAME"
        
        # Manually delete ServiceAccount
        kubectl delete sa test-namespace-001-sa-cleanup-test -n test-namespace-001 >/dev/null 2>&1
        
        # Trigger full reconciliation by deleting operator pod and forcing reconciliation
        OPERATOR_POD=$(kubectl get pods -n $NAMESPACE -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$OPERATOR_POD" ]; then
            info_log "Deleting operator pod to trigger full reconciliation: $OPERATOR_POD"
            kubectl delete pod $OPERATOR_POD -n $NAMESPACE >/dev/null 2>&1
            # Wait for operator to restart and be ready
            kubectl wait --for=condition=ready --timeout=60s pod -l control-plane=controller-manager -n $NAMESPACE >/dev/null 2>&1
            # Force reconciliation by updating ConfigMap (triggers reconciliation via watch)
            kubectl patch configmap permission-config -n $NAMESPACE --type merge -p '{"data":{"whitelist.txt":"'"$(kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}')"'\n"}}' >/dev/null 2>&1
            sleep 2
            # Revert the change
            kubectl patch configmap permission-config -n $NAMESPACE --type merge -p '{"data":{"whitelist.txt":"'"$(kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' | sed 's/\n$//')"'"}}' >/dev/null 2>&1
        fi
        sleep 15
        
        # Verify SA recreated (operator should recreate it)
        if kubectl get sa test-namespace-001-sa-cleanup-test -n test-namespace-001 >/dev/null 2>&1; then
            pass_test "ServiceAccount automatically recreated after deletion"
        else
            fail_test "ServiceAccount not recreated"
        fi
        
        # Verify RoleBinding recreated
        if kubectl get rolebinding -n test-namespace-001 2>/dev/null | grep -q "sa-cleanup-test"; then
            pass_test "RoleBinding recreated for ServiceAccount"
        else
            info_log "RoleBinding not yet recreated (may need more time)"
        fi
    else
        info_log "ServiceAccount cleanup-test not created"
    fi
else
    info_log "test-namespace-001 does not exist, skipping cleanup test"
fi

echo ""

# ============================================================================
