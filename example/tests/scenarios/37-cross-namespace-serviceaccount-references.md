### Test 37: Cross-Namespace ServiceAccount References

**Objective**: Verify ServiceAccounts are created per-namespace and don't cross namespace boundaries

**Background**:
Each namespace should have its own ServiceAccount instances. ServiceAccounts from one namespace cannot be referenced in RoleBindings of another namespace. The operator must create separate SAs per namespace.

**Setup**:
```bash
# Create PermissionBinder with ServiceAccount mapping
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-cross-ns
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    cross-ns-test: view
EOF

# Wait for reconciliation
sleep 10
```

**Execution**:
```bash
# Step 1: Verify SA created in each managed namespace
MANAGED_NAMESPACES=$(kubectl get ns -l permission-binder.io/managed-by=permission-binder-operator -o jsonpath='{.items[*].metadata.name}')

for ns in $MANAGED_NAMESPACES; do
  echo "Checking namespace: $ns"
  
  # Verify SA exists in this namespace
  kubectl get sa ${ns}-sa-cross-ns-test -n $ns && echo "  ✓ SA exists" || echo "  ✗ SA missing"
  
  # Verify RoleBinding references SA from SAME namespace
  RB_SA=$(kubectl get rolebinding -n $ns -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-cross-ns-test")) | .subjects[0].namespace')
  
  if [ "$RB_SA" == "$ns" ]; then
    echo "  ✓ RoleBinding references SA from same namespace"
  else
    echo "  ✗ FAIL: RoleBinding references SA from different namespace: $RB_SA"
  fi
done

# Step 2: Verify SA UIDs are different per namespace (separate instances)
SA_UID_NS1=$(kubectl get sa test-namespace-001-sa-cross-ns-test -n test-namespace-001 -o jsonpath='{.metadata.uid}')
SA_UID_NS2=$(kubectl get sa test-namespace-002-sa-cross-ns-test -n test-namespace-002 -o jsonpath='{.metadata.uid}')

if [ "$SA_UID_NS1" != "$SA_UID_NS2" ]; then
  echo "PASS: ServiceAccounts are separate instances per namespace"
else
  echo "FAIL: ServiceAccounts have same UID (should be different)"
fi

# Step 3: Verify tokens are namespace-specific
TOKEN_NS1=$(kubectl get sa test-namespace-001-sa-cross-ns-test -n test-namespace-001 -o jsonpath='{.secrets[0].name}')
TOKEN_NS2=$(kubectl get sa test-namespace-002-sa-cross-ns-test -n test-namespace-002 -o jsonpath='{.secrets[0].name}')

echo "Token in ns1: $TOKEN_NS1"
echo "Token in ns2: $TOKEN_NS2"

# Step 4: Verify each SA can only access its own namespace
# Create test pod using SA from namespace-001
kubectl run test-pod-sa-ns1 -n test-namespace-001 \
  --image=bitnami/kubectl:latest \
  --serviceaccount=test-namespace-001-sa-cross-ns-test \
  --restart=Never \
  --command -- sleep 3600

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod/test-pod-sa-ns1 -n test-namespace-001 --timeout=60s

# Try to access namespace-002 (should fail - no permissions)
kubectl exec test-pod-sa-ns1 -n test-namespace-001 -- kubectl get pods -n test-namespace-002 2>&1 | grep "Forbidden" && echo "PASS: Cross-namespace access denied" || echo "FAIL: Cross-namespace access allowed"

# Cleanup test pod
kubectl delete pod test-pod-sa-ns1 -n test-namespace-001 --grace-period=0 --force
```

**Expected Result**:
- ✅ ServiceAccount created in each managed namespace
- ✅ Each SA is a separate instance (different UIDs)
- ✅ RoleBindings reference SA from same namespace only
- ✅ Each SA has namespace-specific tokens
- ✅ Cross-namespace access denied (proper isolation)
- ✅ No shared ServiceAccounts across namespaces

**Security Validation**:
- Namespace isolation maintained
- No privilege escalation across namespaces
- Each SA has minimal required permissions

---

