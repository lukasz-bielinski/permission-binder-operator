#!/bin/bash
# Test 31: Serviceaccount Creation
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 31: ServiceAccount Creation"
echo "----------------------------------"

# Create PermissionBinder with SA mapping
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-basic
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: edit
    runtime: view
EOF

sleep 10

# Check if test-namespace-001 exists and has SA
if kubectl get namespace test-namespace-001 >/dev/null 2>&1; then
    SA_DEPLOY=$(kubectl get sa -n test-namespace-001 --no-headers 2>/dev/null | grep "sa-deploy" | wc -l)
    SA_DEPLOY=$(echo "$SA_DEPLOY" | tr -d ' \n')
    SA_RUNTIME=$(kubectl get sa -n test-namespace-001 --no-headers 2>/dev/null | grep "sa-runtime" | wc -l)
    SA_RUNTIME=$(echo "$SA_RUNTIME" | tr -d ' \n')
    
    if [ "$SA_DEPLOY" -gt 0 ] && [ "$SA_RUNTIME" -gt 0 ]; then
        pass_test "ServiceAccounts created (deploy and runtime)"
        
        # Check RoleBindings
        # Use grep with name filter to find RoleBindings for ServiceAccounts
        RB_DEPLOY=$(kubectl get rolebinding -n test-namespace-001 -o name 2>/dev/null | grep -c "sa-.*-deploy" || echo "0")
        RB_RUNTIME=$(kubectl get rolebinding -n test-namespace-001 -o name 2>/dev/null | grep -c "sa-.*-runtime" || echo "0")
        
        if [ "$RB_DEPLOY" -gt 0 ] && [ "$RB_RUNTIME" -gt 0 ]; then
            pass_test "ServiceAccount RoleBindings created"
        else
            fail_test "ServiceAccount RoleBindings not created"
        fi
    else
        fail_test "ServiceAccounts not created (deploy: $SA_DEPLOY, runtime: $SA_RUNTIME)"
    fi
else
    info_log "test-namespace-001 does not exist, skipping SA creation test"
fi

echo ""

# ============================================================================
