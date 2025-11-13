### Test 31: ServiceAccount Creation

**Objective**: Verify basic ServiceAccount creation and RoleBinding

**Setup**:
```bash
# Create PermissionBinder with SA mapping
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-basic
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: edit
    runtime: view
EOF
```

**Execution**:
```bash
# Wait for reconciliation
sleep 5

# Verify ServiceAccounts created
kubectl get sa -n test-namespace-001 | grep "sa-deploy"
kubectl get sa -n test-namespace-001 | grep "sa-runtime"

# Verify RoleBindings created
kubectl get rolebinding -n test-namespace-001 | grep "sa-deploy"
kubectl get rolebinding -n test-namespace-001 | grep "sa-runtime"
```

**Expected Result**:
- ServiceAccounts `test-namespace-001-sa-deploy` and `test-namespace-001-sa-runtime` exist
- RoleBindings created for both ServiceAccounts
- deploy SA has edit role, runtime SA has view role

---

