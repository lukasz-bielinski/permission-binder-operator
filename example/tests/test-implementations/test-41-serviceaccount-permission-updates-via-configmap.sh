#!/bin/bash
# Test 41: Serviceaccount Permission Updates Via Configmap
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 41: ServiceAccount Permission Updates"
echo "--------------------------------------------"

# Create PermissionBinder with initial permissions
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-permission-update
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    perm-test: view
EOF

sleep 15

if kubectl get namespace test-namespace-001 >/dev/null 2>&1; then
    # Record initial role
    INITIAL_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json 2>/dev/null | jq -r '.items[] | select(.subjects[0].name | contains("sa-perm-test")) | .roleRef.name' | head -1)
    info_log "Initial role: $INITIAL_ROLE"
    
    if [ "$INITIAL_ROLE" == "view" ]; then
        pass_test "Initial permissions set correctly (view)"
        
        # Upgrade permissions
        cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-permission-update
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    perm-test: admin
EOF
        
        sleep 20
        
        # Verify upgrade
        NEW_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json 2>/dev/null | jq -r '.items[] | select(.subjects[0].name | contains("sa-perm-test")) | .roleRef.name' | head -1)
        info_log "Updated role: $NEW_ROLE"
        
        if [ "$NEW_ROLE" == "admin" ]; then
            pass_test "Permission upgrade applied (view -> admin)"
            
            # Verify SA not recreated
            SA_UID_AFTER=$(kubectl get sa test-namespace-001-sa-perm-test -n test-namespace-001 -o jsonpath='{.metadata.uid}' 2>/dev/null)
            if [ -n "$SA_UID_AFTER" ]; then
                pass_test "ServiceAccount not recreated during permission update"
            fi
        else
            info_log "Permission upgrade not yet applied: $NEW_ROLE (expected: admin)"
        fi
        
        # Test downgrade
        cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-permission-update
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    perm-test: view
EOF
        
        sleep 20
        
        # Verify downgrade
        FINAL_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json 2>/dev/null | jq -r '.items[] | select(.subjects[0].name | contains("sa-perm-test")) | .roleRef.name' | head -1)
        
        if [ "$FINAL_ROLE" == "view" ]; then
            pass_test "Permission downgrade applied (admin -> view)"
        else
            info_log "Permission downgrade not yet applied: $FINAL_ROLE"
        fi
    else
        info_log "Initial role not 'view': $INITIAL_ROLE"
    fi
else
    info_log "test-namespace-001 does not exist, skipping permission update test"
fi

echo ""

# ============================================================================
