### Test 36: ServiceAccount Deletion and Cleanup (Orphaned RoleBindings)

**Objective**: Verify operator cleans up orphaned RoleBindings when ServiceAccount is manually deleted

**Background**:
When a ServiceAccount is manually deleted (e.g., by admin), any RoleBindings referencing it become orphaned and non-functional. The operator should detect this and clean up orphaned RoleBindings.

**Setup**:
```bash
# Create PermissionBinder with ServiceAccount mapping
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-cleanup
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    cleanup-test: edit
EOF

# Wait for SA and RoleBinding creation
sleep 10

# Verify SA and RoleBinding exist
kubectl get sa test-namespace-001-sa-cleanup-test -n test-namespace-001
kubectl get rolebinding -n test-namespace-001 | grep "sa-cleanup-test"
```

**Execution**:
```bash
# Step 1: Record RoleBinding name
RB_NAME=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-cleanup-test")) | .metadata.name')
echo "RoleBinding: $RB_NAME"

# Step 2: Manually delete ServiceAccount (simulating manual cleanup)
kubectl delete sa test-namespace-001-sa-cleanup-test -n test-namespace-001

# Verify SA deleted
kubectl get sa test-namespace-001-sa-cleanup-test -n test-namespace-001 2>&1 | grep "NotFound" && echo "SA deleted successfully"

# Step 3: Trigger reconciliation (add annotation to PermissionBinder)
kubectl annotate permissionbinder test-sa-cleanup -n permissions-binder-operator trigger-reconcile="$(date +%s)" --overwrite

# Wait for operator to reconcile
sleep 15

# Step 4: Verify orphaned RoleBinding detected and cleaned up
kubectl get rolebinding $RB_NAME -n test-namespace-001 2>&1 | grep "NotFound" && echo "PASS: Orphaned RoleBinding cleaned up" || echo "FAIL: Orphaned RoleBinding still exists"

# Step 5: Verify operator logs cleanup event
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=50 | jq 'select(.message | contains("orphaned") or contains("cleanup"))'

# Step 6: Verify ServiceAccount recreated (operator should recreate it)
sleep 10
kubectl get sa test-namespace-001-sa-cleanup-test -n test-namespace-001 && echo "PASS: SA recreated by operator" || echo "FAIL: SA not recreated"

# Step 7: Verify new RoleBinding created
kubectl get rolebinding -n test-namespace-001 | grep "sa-cleanup-test" && echo "PASS: RoleBinding recreated" || echo "FAIL: RoleBinding not recreated"
```

**Expected Result**:
- ✅ Operator detects manually deleted ServiceAccount
- ✅ Orphaned RoleBinding cleaned up
- ✅ Operator recreates ServiceAccount (matches desired state)
- ✅ New RoleBinding created for recreated SA
- ✅ JSON logs show cleanup action with context
- ✅ No stuck orphaned resources

**Log Verification**:
```bash
# Expected log entry (JSON)
{
  "level": "info",
  "timestamp": "...",
  "message": "Cleaning up orphaned RoleBinding",
  "action": "cleanup_orphaned_rolebinding",
  "namespace": "test-namespace-001",
  "rolebinding": "...",
  "reason": "ServiceAccount not found",
  "serviceAccount": "test-namespace-001-sa-cleanup-test"
}
```

---

