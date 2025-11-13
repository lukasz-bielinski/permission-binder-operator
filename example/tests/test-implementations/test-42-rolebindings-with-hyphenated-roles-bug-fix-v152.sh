#!/bin/bash
# Test 42: Rolebindings With Hyphenated Roles Bug Fix V152
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 42: RoleBindings with Hyphenated Roles (Bug Fix v1.5.2)"
echo "-------------------------------------------------------------"

# Create PermissionBinder with hyphenated role mappings
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-hyphenated-roles
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: edit
    "read-only": view
    "cluster-admin": cluster-admin
    admin: admin
EOF

# Create ConfigMap entries with hyphenated roles
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: $NAMESPACE
data:
  whitelist.txt: |-
    CN=COMPANY-K8S-test-hyphenated-read-only,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-test-hyphenated-cluster-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-test-hyphenated-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
EOF

sleep 15

# Verify RoleBindings created for hyphenated roles
if kubectl get namespace test-hyphenated >/dev/null 2>&1; then
    if kubectl get rolebinding test-hyphenated-read-only -n test-hyphenated >/dev/null 2>&1; then
        pass_test "read-only RoleBinding created"
    else
        fail_test "read-only RoleBinding missing"
    fi
    
    if kubectl get rolebinding test-hyphenated-cluster-admin -n test-hyphenated >/dev/null 2>&1; then
        pass_test "cluster-admin RoleBinding created"
    else
        fail_test "cluster-admin RoleBinding missing"
    fi
    
    # Verify AnnotationRole annotation stores full role name
    READ_ONLY_ROLE=$(kubectl get rolebinding test-hyphenated-read-only -n test-hyphenated -o jsonpath='{.metadata.annotations.permission-binder\.io/role}' 2>/dev/null)
    CLUSTER_ADMIN_ROLE=$(kubectl get rolebinding test-hyphenated-cluster-admin -n test-hyphenated -o jsonpath='{.metadata.annotations.permission-binder\.io/role}' 2>/dev/null)
    
    if [ "$READ_ONLY_ROLE" == "read-only" ]; then
        pass_test "AnnotationRole correctly stores 'read-only'"
    else
        fail_test "AnnotationRole should be 'read-only', got: $READ_ONLY_ROLE"
    fi
    
    if [ "$CLUSTER_ADMIN_ROLE" == "cluster-admin" ]; then
        pass_test "AnnotationRole correctly stores 'cluster-admin'"
    else
        fail_test "AnnotationRole should be 'cluster-admin', got: $CLUSTER_ADMIN_ROLE"
    fi
    
    # Trigger reconciliation (this previously caused deletion bug)
    kubectl annotate permissionbinder test-hyphenated-roles -n $NAMESPACE trigger-reconcile="$(date +%s)" --overwrite >/dev/null 2>&1
    sleep 10
    
    # Verify RoleBindings NOT deleted (bug fix verification)
    if kubectl get rolebinding test-hyphenated-read-only -n test-hyphenated >/dev/null 2>&1; then
        pass_test "read-only RoleBinding NOT deleted after reconciliation"
    else
        fail_test "read-only RoleBinding was deleted!"
    fi
    
    if kubectl get rolebinding test-hyphenated-cluster-admin -n test-hyphenated >/dev/null 2>&1; then
        pass_test "cluster-admin RoleBinding NOT deleted after reconciliation"
    else
        fail_test "cluster-admin RoleBinding was deleted!"
    fi
    
    # Verify no "Deleted obsolete RoleBinding" logs for hyphenated roles
    OBSOLETE_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=100 2>/dev/null | jq -r 'select(.message | contains("Deleted obsolete RoleBinding")) | select(.name | contains("read-only") or contains("cluster-admin"))' 2>/dev/null || echo "")
    
    if [ -z "$OBSOLETE_LOGS" ]; then
        pass_test "No incorrect deletion logs for hyphenated roles"
    else
        fail_test "Found incorrect deletion logs: $OBSOLETE_LOGS"
    fi
    
    # Test role removal from mapping (should delete correctly)
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-hyphenated-roles
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: edit
    admin: admin
EOF
    
    sleep 15
    
    # Verify hyphenated role RoleBindings ARE deleted when role removed from mapping
    if ! kubectl get rolebinding test-hyphenated-read-only -n test-hyphenated >/dev/null 2>&1; then
        pass_test "read-only RoleBinding correctly deleted when role removed"
    else
        fail_test "read-only RoleBinding should be deleted"
    fi
    
    if ! kubectl get rolebinding test-hyphenated-cluster-admin -n test-hyphenated >/dev/null 2>&1; then
        pass_test "cluster-admin RoleBinding correctly deleted when role removed"
    else
        fail_test "cluster-admin RoleBinding should be deleted"
    fi
    
    # Verify engineer RoleBinding still exists (not removed)
    if kubectl get rolebinding test-hyphenated-engineer -n test-hyphenated >/dev/null 2>&1; then
        pass_test "engineer RoleBinding preserved (role still in mapping)"
    else
        fail_test "engineer RoleBinding incorrectly deleted"
    fi
else
    info_log "test-hyphenated namespace does not exist, skipping hyphenated roles test"
fi

echo ""

# ============================================================================
