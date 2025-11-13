### Test 39: ServiceAccount Special Characters and Edge Cases

**Objective**: Verify operator handles edge cases in ServiceAccount names and configurations

**Background**:
Kubernetes has strict naming rules. ServiceAccount names must be valid DNS-1123 subdomain names. The operator should validate names and handle edge cases gracefully.

**Test Cases**:

#### Test 39.1: Valid Special Characters (Hyphens)
```bash
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-special-chars
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    my-deploy-sa: edit
    test-runtime-123: view
    sa-with-many-hyphens: view
EOF

sleep 10

# Verify valid names accepted
kubectl get sa -n test-namespace-001 | grep "my-deploy-sa" && echo "PASS: Hyphens supported"
kubectl get sa -n test-namespace-001 | grep "test-runtime-123" && echo "PASS: Numbers supported"
kubectl get sa -n test-namespace-001 | grep "sa-with-many-hyphens" && echo "PASS: Multiple hyphens supported"
```

#### Test 39.2: Invalid Characters (Should be rejected or sanitized)
```bash
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-invalid
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    "UPPERCASE_SA": edit
    "sa.with.dots": view
    "sa_with_underscores": view
EOF

sleep 10

# Check operator logs for validation errors
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=50 | jq 'select(.level=="error" or .level=="warning") | select(.message | contains("invalid") or contains("ServiceAccount"))'

# Verify invalid names rejected (SA not created)
kubectl get sa -n test-namespace-001 | grep "UPPERCASE_SA" && echo "FAIL: Invalid name accepted" || echo "PASS: Invalid name rejected"
```

#### Test 39.3: Name Length Limits
```bash
# Max length for K8s resource name: 253 characters
LONG_NAME="sa-$(printf 'a%.0s' {1..250})"

kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-long-name
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    "${LONG_NAME}": view
EOF

sleep 10

# Check if operator handles long names
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=50 | jq 'select(.message | contains("name too long") or contains("exceeds"))'
```

#### Test 39.4: Empty ServiceAccount Mapping
```bash
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-empty
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping: {}
EOF

sleep 5

# Verify no crash, logs show empty mapping
kubectl get pod -n permissions-binder-operator -l control-plane=controller-manager -o jsonpath='{.items[0].status.phase}' | grep "Running" && echo "PASS: No crash with empty mapping"
```

**Expected Result**:
- ✅ Valid characters (hyphens, numbers) supported
- ✅ Invalid characters (uppercase, dots, underscores) rejected with clear error
- ✅ Name length validation (max 253 chars)
- ✅ Empty mapping handled gracefully
- ✅ Clear JSON logs for validation errors
- ✅ No operator crash on invalid input
- ✅ Valid entries processed even if some are invalid

---

