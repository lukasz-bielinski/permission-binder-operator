#!/bin/bash
# Test 35: Serviceaccount Protection Safe Mode
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 35: ServiceAccount Protection (SAFE MODE)"
echo "-----------------------------------------------"

# Create PermissionBinder with ServiceAccount mapping
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-protection
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

sleep 15

# Verify ServiceAccounts exist
if kubectl get namespace test-namespace-001 >/dev/null 2>&1; then
    SA_DEPLOY_UID=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.uid}' 2>/dev/null)
    SA_RUNTIME_UID=$(kubectl get sa test-namespace-001-sa-runtime -n test-namespace-001 -o jsonpath='{.metadata.uid}' 2>/dev/null)
    
    if [ -n "$SA_DEPLOY_UID" ] && [ -n "$SA_RUNTIME_UID" ]; then
        info_log "ServiceAccounts created (deploy: ${SA_DEPLOY_UID:0:8}..., runtime: ${SA_RUNTIME_UID:0:8}...)"
        
        # Remove ServiceAccount mapping
        cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-protection
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
        
        sleep 15
        
        # Verify SAs still exist (SAFE MODE)
        NEW_SA_DEPLOY_UID=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.uid}' 2>/dev/null)
        NEW_SA_RUNTIME_UID=$(kubectl get sa test-namespace-001-sa-runtime -n test-namespace-001 -o jsonpath='{.metadata.uid}' 2>/dev/null)
        
        if [ "$SA_DEPLOY_UID" == "$NEW_SA_DEPLOY_UID" ] && [ "$SA_RUNTIME_UID" == "$NEW_SA_RUNTIME_UID" ]; then
            pass_test "ServiceAccounts NEVER deleted (SAFE MODE)"
            
            # Check orphaned annotations
            ORPHANED_ANNOTATION=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.annotations.permission-binder\.io/orphaned-at}' 2>/dev/null)
            if [ -n "$ORPHANED_ANNOTATION" ]; then
                pass_test "Orphaned annotation added to ServiceAccounts"
            else
                info_log "Orphaned annotation not yet added (may need more time)"
            fi
        else
            fail_test "ServiceAccounts were deleted or recreated"
        fi
    else
        info_log "ServiceAccounts not created in previous tests"
    fi
else
    info_log "test-namespace-001 does not exist, skipping SA protection test"
fi

echo ""

# ============================================================================
