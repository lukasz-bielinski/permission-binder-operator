### Test 32: ServiceAccount Naming Pattern

**Objective**: Verify custom naming pattern works correctly

**Setup**:
```bash
# Create PermissionBinder with custom pattern
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-pattern
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
  serviceAccountNamingPattern: "sa-{namespace}-{name}"
EOF
```

**Execution**:
```bash
# Wait for reconciliation
sleep 5

# Verify SA with custom pattern
kubectl get sa -n test-namespace-001 sa-test-namespace-001-deploy
```

**Expected Result**:
- ServiceAccount named `sa-test-namespace-001-deploy` exists
- Pattern `sa-{namespace}-{name}` correctly applied

---

