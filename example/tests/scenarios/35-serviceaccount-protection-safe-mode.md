### Test 35: ServiceAccount Protection (SAFE MODE)

**Objective**: Verify operator NEVER deletes ServiceAccounts it created

**Background**: 
Similar to namespace protection (Test 7), ServiceAccounts should never be deleted by the operator. This prevents service disruptions and maintains security tokens/secrets. When a ServiceAccount is no longer needed, it should be marked with an annotation, not deleted.

**Setup**:
```bash
# Create PermissionBinder with ServiceAccount mapping
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-protection
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

# Wait for ServiceAccounts to be created
sleep 10

# Verify ServiceAccounts exist
kubectl get sa -n test-namespace-001 | grep "sa-deploy"
kubectl get sa -n test-namespace-001 | grep "sa-runtime"
```

**Execution**:
```bash
# Step 1: Record ServiceAccount UIDs
SA_DEPLOY_UID=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.uid}')
SA_RUNTIME_UID=$(kubectl get sa test-namespace-001-sa-runtime -n test-namespace-001 -o jsonpath='{.metadata.uid}')

echo "Deploy SA UID: $SA_DEPLOY_UID"
echo "Runtime SA UID: $SA_RUNTIME_UID"

# Step 2: Remove ServiceAccount mapping from PermissionBinder
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-protection
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping: {}  # REMOVED ALL ServiceAccounts
EOF

# Wait for reconciliation
sleep 10

# Step 3: Verify ServiceAccounts still exist
kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 || echo "FAIL: SA was deleted!"
kubectl get sa test-namespace-001-sa-runtime -n test-namespace-001 || echo "FAIL: SA was deleted!"

# Step 4: Verify UIDs unchanged (not recreated)
NEW_SA_DEPLOY_UID=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.uid}')
NEW_SA_RUNTIME_UID=$(kubectl get sa test-namespace-001-sa-runtime -n test-namespace-001 -o jsonpath='{.metadata.uid}')

if [ "$SA_DEPLOY_UID" == "$NEW_SA_DEPLOY_UID" ]; then
  echo "PASS: Deploy SA preserved (UID unchanged)"
else
  echo "FAIL: Deploy SA was recreated or deleted"
fi

if [ "$SA_RUNTIME_UID" == "$NEW_SA_RUNTIME_UID" ]; then
  echo "PASS: Runtime SA preserved (UID unchanged)"
else
  echo "FAIL: Runtime SA was recreated or deleted"
fi

# Step 5: Verify orphaned annotation added
DEPLOY_ANNOTATION=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.annotations.permission-binder\.io/orphaned-at}')
RUNTIME_ANNOTATION=$(kubectl get sa test-namespace-001-sa-runtime -n test-namespace-001 -o jsonpath='{.metadata.annotations.permission-binder\.io/orphaned-at}')

if [ -n "$DEPLOY_ANNOTATION" ]; then
  echo "PASS: Deploy SA has orphaned-at annotation: $DEPLOY_ANNOTATION"
else
  echo "FAIL: Deploy SA missing orphaned-at annotation"
fi

if [ -n "$RUNTIME_ANNOTATION" ]; then
  echo "PASS: Runtime SA has orphaned-at annotation: $RUNTIME_ANNOTATION"
else
  echo "FAIL: Runtime SA missing orphaned-at annotation"
fi

# Step 6: Verify associated RoleBindings removed
kubectl get rolebinding -n test-namespace-001 | grep "sa-deploy" && echo "WARN: RoleBinding still exists" || echo "PASS: RoleBinding removed"
kubectl get rolebinding -n test-namespace-001 | grep "sa-runtime" && echo "WARN: RoleBinding still exists" || echo "PASS: RoleBinding removed"
```

**Expected Result**:
- ✅ ServiceAccounts NEVER deleted (SAFE MODE)
- ✅ ServiceAccount UIDs unchanged (not recreated)
- ✅ Orphaned annotation added: `permission-binder.io/orphaned-at=<timestamp>`
- ✅ Orphaned annotation added: `permission-binder.io/orphaned-by=<permissionbinder-name>`
- ✅ Associated RoleBindings removed (only bindings, not SAs)
- ✅ ServiceAccounts remain functional (tokens/secrets preserved)

**Security Rationale**:
1. **Token Preservation**: ServiceAccount tokens/secrets must not be invalidated
2. **Pod Continuity**: Running pods using these SAs should not be disrupted
3. **Manual Cleanup**: Admin can manually delete SAs when ready
4. **Audit Trail**: Orphaned annotation provides clear history

**Recovery Test**:
```bash
# Step 7: Re-add ServiceAccount mapping
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-protection
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

# Wait for reconciliation
sleep 10

# Step 8: Verify orphaned annotation removed (adoption)
DEPLOY_ANNOTATION=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.annotations.permission-binder\.io/orphaned-at}')
RUNTIME_ANNOTATION=$(kubectl get sa test-namespace-001-sa-runtime -n test-namespace-001 -o jsonpath='{.metadata.annotations.permission-binder\.io/orphaned-at}')

if [ -z "$DEPLOY_ANNOTATION" ]; then
  echo "PASS: Deploy SA orphaned-at annotation removed (adopted)"
else
  echo "FAIL: Deploy SA still has orphaned-at annotation"
fi

if [ -z "$RUNTIME_ANNOTATION" ]; then
  echo "PASS: Runtime SA orphaned-at annotation removed (adopted)"
else
  echo "FAIL: Runtime SA still has orphaned-at annotation"
fi

# Step 9: Verify RoleBindings recreated
kubectl get rolebinding -n test-namespace-001 | grep "sa-deploy" || echo "FAIL: RoleBinding not recreated"
kubectl get rolebinding -n test-namespace-001 | grep "sa-runtime" || echo "FAIL: RoleBinding not recreated"
```

**Expected Recovery Result**:
- ✅ ServiceAccounts automatically adopted (orphaned annotations removed)
- ✅ RoleBindings recreated
- ✅ Full functionality restored
- ✅ Zero downtime for existing pods using these SAs

**Related Tests**:
- Test 7: Namespace Protection (similar SAFE MODE behavior)
- Test 8: PermissionBinder Deletion (SAFE MODE for all resources)
- Test 14: Orphaned Resources Adoption (automatic recovery)

---

