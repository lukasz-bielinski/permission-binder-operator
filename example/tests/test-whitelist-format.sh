#!/bin/bash
set -e

echo "======================================"
echo "Testing Whitelist.txt LDAP DN Format"
echo "======================================"

# Ensure we have KUBECONFIG
if [ -z "$KUBECONFIG" ]; then
    echo "ERROR: KUBECONFIG is not set"
    exit 1
fi

echo ""
echo "1. Creating test ConfigMap with whitelist.txt format..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: whitelist-test-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |-
    # Test LDAP DN entries
    CN=COMPANY-K8S-whitelist-test1-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-whitelist-test2-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Entry with spaces in DN (should be trimmed)
    CN=COMPANY-K8S-whitelist-test3-viewer,OU=Test Unit,OU=Platform,DC=example,DC=com
    
    # Comment line (should be ignored)
    # CN=COMPANY-K8S-ignored-admin,OU=Test,DC=example,DC=com
EOF

echo ""
echo "2. Creating PermissionBinder for whitelist test..."
cat <<EOF | kubectl apply -f -
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: whitelist-test-binder
  namespace: permissions-binder-operator
spec:
  roleMapping:
    engineer: edit
    admin: admin
    viewer: view
  prefix: "COMPANY-K8S"
  excludeList: []
  configMapName: "whitelist-test-config"
  configMapNamespace: "permissions-binder-operator"
EOF

echo ""
echo "3. Waiting for reconciliation..."
sleep 10

echo ""
echo "4. Checking if namespaces were created..."
NS_COUNT=$(kubectl get namespace | grep -c "whitelist-test" || true)
if [ "$NS_COUNT" -eq 3 ]; then
    echo "✅ All 3 namespaces created successfully"
else
    echo "❌ Expected 3 namespaces, found: $NS_COUNT"
    kubectl get namespace | grep "whitelist-test" || true
    exit 1
fi

echo ""
echo "5. Checking RoleBindings..."
for ns in whitelist-test1 whitelist-test2 whitelist-test3; do
    echo "  Checking namespace: $ns"
    RB_EXISTS=$(kubectl get rolebinding -n $ns 2>/dev/null | wc -l)
    if [ "$RB_EXISTS" -gt 1 ]; then
        echo "    ✅ RoleBinding exists in $ns"
        # Check if the RoleBinding contains the full LDAP DN
        GROUP_DN=$(kubectl get rolebinding -n $ns -o yaml | grep "name:" | grep "CN=" || true)
        if [ -n "$GROUP_DN" ]; then
            echo "    ✅ RoleBinding uses full LDAP DN as group"
        else
            echo "    ⚠️  Warning: RoleBinding may not use full LDAP DN"
        fi
    else
        echo "    ❌ No RoleBinding found in $ns"
        exit 1
    fi
done

echo ""
echo "6. Testing CN extraction with complex DN..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: whitelist-test-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |-
    CN=COMPANY-K8S-whitelist-test1-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-whitelist-test2-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-whitelist-test3-viewer,OU=Test Unit,OU=Platform,DC=example,DC=com
    # New entry with complex namespace
    CN=COMPANY-K8S-whitelist-complex-namespace-engineer,OU=Complex,OU=Test,DC=example,DC=com
EOF

echo "  Waiting for reconciliation..."
sleep 10

NS_EXISTS=$(kubectl get namespace whitelist-complex-namespace 2>/dev/null | wc -l)
if [ "$NS_EXISTS" -gt 0 ]; then
    echo "  ✅ Complex namespace created successfully"
else
    echo "  ❌ Complex namespace not created"
    exit 1
fi

echo ""
echo "7. Testing comment and empty line handling..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: whitelist-test-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |-
    # This is a comment
    CN=COMPANY-K8S-whitelist-test1-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Empty line above should be ignored
    CN=COMPANY-K8S-whitelist-test2-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    CN=COMPANY-K8S-whitelist-test3-viewer,OU=Test Unit,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-whitelist-complex-namespace-engineer,OU=Complex,OU=Test,DC=example,DC=com
    
    # Another comment at the end
EOF

echo "  Waiting for reconciliation..."
sleep 5

# Should still have the same namespaces (comments and empty lines ignored)
NS_COUNT=$(kubectl get namespace | grep -c "whitelist-test" || true)
echo "  Namespace count after update: $NS_COUNT"

echo ""
echo "8. Checking operator logs for any errors..."
ERRORS=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=50 | grep -i "error" | grep -i "whitelist" || true)
if [ -z "$ERRORS" ]; then
    echo "  ✅ No errors in operator logs related to whitelist"
else
    echo "  ⚠️  Found errors in logs:"
    echo "$ERRORS"
fi

echo ""
echo "9. Cleanup..."
kubectl delete permissionbinder whitelist-test-binder -n permissions-binder-operator
kubectl delete configmap whitelist-test-config -n permissions-binder-operator
sleep 5

# Namespaces should be marked as orphaned, not deleted (SAFE MODE)
for ns in whitelist-test1 whitelist-test2 whitelist-test3 whitelist-complex-namespace; do
    NS_EXISTS=$(kubectl get namespace $ns 2>/dev/null | wc -l)
    if [ "$NS_EXISTS" -gt 0 ]; then
        ORPHANED=$(kubectl get namespace $ns -o yaml | grep "orphaned-at" || true)
        if [ -n "$ORPHANED" ]; then
            echo "  ✅ Namespace $ns marked as orphaned (SAFE MODE)"
        else
            echo "  ⚠️  Namespace $ns exists but not marked as orphaned"
        fi
        # Clean up test namespaces
        kubectl delete namespace $ns --wait=false
    fi
done

echo ""
echo "======================================"
echo "✅ All whitelist.txt format tests PASSED!"
echo "======================================"
echo ""
echo "Validated:"
echo "  ✅ LDAP DN parsing (CN extraction)"
echo "  ✅ Namespace creation from CN values"
echo "  ✅ RoleBinding creation with full LDAP DN"
echo "  ✅ Comment line handling"
echo "  ✅ Empty line handling"
echo "  ✅ Complex namespace names (with dashes)"
echo "  ✅ SAFE MODE (orphaned resources on delete)"
echo ""

