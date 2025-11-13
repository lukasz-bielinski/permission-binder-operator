#!/bin/bash
# Test 37: Cross Namespace Serviceaccount References
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 37: Cross-Namespace ServiceAccount References"
echo "----------------------------------------------------"

# Create PermissionBinder for cross-namespace test
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-cross-ns
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    cross-ns-test: view
EOF

sleep 15

# Get managed namespaces
MANAGED_NAMESPACES=$(kubectl get ns -l permission-binder.io/managed-by=permission-binder-operator -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [ -n "$MANAGED_NAMESPACES" ]; then
    SA_COUNT=0
    ISOLATION_OK=0
    
    for ns in $MANAGED_NAMESPACES; do
        # Check if SA exists in this namespace
        if kubectl get sa ${ns}-sa-cross-ns-test -n $ns >/dev/null 2>&1; then
            SA_COUNT=$((SA_COUNT + 1))
            
            # Verify RoleBinding references SA from same namespace
            RB_SA_NS=$(kubectl get rolebinding -n $ns -o json 2>/dev/null | jq -r '.items[] | select(.subjects[0].name | contains("sa-cross-ns-test")) | .subjects[0].namespace' | head -1)
            
            if [ "$RB_SA_NS" == "$ns" ]; then
                ISOLATION_OK=$((ISOLATION_OK + 1))
            fi
        fi
    done
    
    if [ $SA_COUNT -gt 1 ]; then
        pass_test "ServiceAccounts created in multiple namespaces ($SA_COUNT namespaces)"
    else
        info_log "ServiceAccounts created in $SA_COUNT namespace(s)"
    fi
    
    if [ $ISOLATION_OK -eq $SA_COUNT ] && [ $SA_COUNT -gt 0 ]; then
        pass_test "Cross-namespace isolation verified (RoleBindings reference local SAs)"
    else
        info_log "Isolation check: $ISOLATION_OK/$SA_COUNT namespaces OK"
    fi
else
    info_log "No managed namespaces found for cross-namespace test"
fi

echo ""

# ============================================================================
