### Test 58: NetworkPolicy - Disabled Mode

**Objective**: Verify that when `networkPolicy.enabled` is set to `false`, the operator skips NetworkPolicy reconciliation (no PRs, no status updates, no metrics noise).

**Setup**:
```bash
# Create PermissionBinder with NetworkPolicy disabled
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-permissionbinder-networkpolicy-disabled
  namespace: permissions-binder-operator
spec:
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: "edit"
  configMapName: "permission-config-disabled"
  configMapNamespace: "permissions-binder-operator"
  networkPolicy:
    enabled: false
EOF

# Create ConfigMap with namespaces (should be ignored for NetworkPolicy)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config-disabled
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-disabled-engineer,OU=Openshift,DC=example,DC=com
EOF
```

**Execution**:
```bash
sleep 10  # Wait briefly to allow reconciliation loop to run

# Verify that no NetworkPolicy status was created
kubectl get permissionbinder test-permissionbinder-networkpolicy-disabled -n permissions-binder-operator -o jsonpath='{.status.networkPolicies}'

# Check that NetworkPolicy metrics remain unchanged (no PRs created)
curl -s http://localhost:8080/metrics | grep 'permission_binder_networkpolicy_prs_created_total'
```

**Expected Result**:
- ✅ `status.networkPolicies` is empty (or absent)
- ✅ No NetworkPolicy PR metrics incremented
- ✅ Operator logs show explicit skip message (`networkPolicy.enabled=false`) without errors
- ✅ Operator remains healthy (deployment Ready)

**Cleanup**:
```bash
kubectl delete permissionbinder test-permissionbinder-networkpolicy-disabled -n permissions-binder-operator
kubectl delete configmap permission-config-disabled -n permissions-binder-operator
```

---
