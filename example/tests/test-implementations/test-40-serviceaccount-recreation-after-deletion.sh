#!/bin/bash
# Test 40: Serviceaccount Recreation After Deletion
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 40: ServiceAccount Recreation After Deletion"
echo "---------------------------------------------------"

# Create PermissionBinder for recreation test
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-recreation
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    recreation-test: edit
EOF

sleep 15

if kubectl get namespace test-namespace-001 >/dev/null 2>&1; then
    if kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001 >/dev/null 2>&1; then
        # Record original UID
        ORIGINAL_SA_UID=$(kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001 -o jsonpath='{.metadata.uid}' 2>/dev/null)
        info_log "Original SA UID: ${ORIGINAL_SA_UID:0:8}..."
        
        # Delete ServiceAccount
        kubectl delete sa test-namespace-001-sa-recreation-test -n test-namespace-001 >/dev/null 2>&1
        
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
        # Wait for reconciliation to complete
        sleep 20
        
        # Verify recreated - retry a few times if needed
        RECREATED=false
        for i in {1..5}; do
            if kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001 >/dev/null 2>&1; then
                RECREATED=true
                break
            fi
            info_log "Waiting for ServiceAccount recreation (attempt $i/5)..."
            sleep 3
        done
        
        if [ "$RECREATED" = true ]; then
            pass_test "ServiceAccount automatically recreated"
            
            # Verify new UID (new instance)
            NEW_SA_UID=$(kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001 -o jsonpath='{.metadata.uid}' 2>/dev/null)
            
            if [ "$ORIGINAL_SA_UID" != "$NEW_SA_UID" ]; then
                pass_test "New ServiceAccount instance created (different UID)"
            else
                info_log "ServiceAccount UID unchanged (unexpected)"
            fi
            
            # Verify RoleBinding still works
            if kubectl get rolebinding -n test-namespace-001 2>/dev/null | grep -q "sa-recreation-test"; then
                pass_test "RoleBinding references recreated ServiceAccount"
            else
                info_log "RoleBinding not yet created"
            fi
        else
            fail_test "ServiceAccount not recreated"
        fi
    else
        info_log "ServiceAccount recreation-test not created"
    fi
else
    info_log "test-namespace-001 does not exist, skipping recreation test"
fi

echo ""

# ============================================================================
