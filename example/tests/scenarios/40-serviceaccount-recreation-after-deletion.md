### Test 40: ServiceAccount Recreation After Deletion

**Objective**: Verify operator recreates deleted ServiceAccount and maintains consistency

**Background**:
If a ServiceAccount is accidentally or intentionally deleted, the operator should detect the deletion and recreate it to match the desired state defined in PermissionBinder.

**Setup**:
```bash
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-recreation
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    recreation-test: edit
EOF

sleep 10

# Verify SA created
kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001
```

**Execution**:
```bash
# Step 1: Record original ServiceAccount details
ORIGINAL_SA_UID=$(kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001 -o jsonpath='{.metadata.uid}')
ORIGINAL_SA_SECRET=$(kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001 -o jsonpath='{.secrets[0].name}')

echo "Original SA UID: $ORIGINAL_SA_UID"
echo "Original SA Secret: $ORIGINAL_SA_SECRET"

# Step 2: Delete ServiceAccount
kubectl delete sa test-namespace-001-sa-recreation-test -n test-namespace-001

# Verify deleted
kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001 2>&1 | grep "NotFound" && echo "SA deleted"

# Step 3: Trigger reconciliation
kubectl annotate permissionbinder test-sa-recreation -n permissions-binder-operator force-reconcile="$(date +%s)" --overwrite

# Wait for operator to detect and recreate
sleep 15

# Step 4: Verify SA recreated
kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001 && echo "PASS: SA recreated" || echo "FAIL: SA not recreated"

# Step 5: Verify new UID (new instance)
NEW_SA_UID=$(kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001 -o jsonpath='{.metadata.uid}')

if [ "$ORIGINAL_SA_UID" != "$NEW_SA_UID" ]; then
  echo "PASS: New ServiceAccount instance created (different UID)"
else
  echo "FAIL: Same UID (should be different after recreation)"
fi

# Step 6: Verify RoleBinding still works
RB_SA_NAME=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-recreation-test")) | .subjects[0].name')

echo "RoleBinding references SA: $RB_SA_NAME"

if [ "$RB_SA_NAME" == "test-namespace-001-sa-recreation-test" ]; then
  echo "PASS: RoleBinding references correct SA"
else
  echo "FAIL: RoleBinding reference broken"
fi

# Step 7: Verify new token created
NEW_SA_SECRET=$(kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001 -o jsonpath='{.secrets[0].name}')

echo "New SA Secret: $NEW_SA_SECRET"

# Step 8: Verify operator logs recreation event
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=100 | jq 'select(.message | contains("created") or contains("ServiceAccount")) | select(.namespace=="test-namespace-001")'

# Step 9: Multiple deletion test (stress test)
echo "Stress test: Multiple rapid deletions"
for i in {1..3}; do
  kubectl delete sa test-namespace-001-sa-recreation-test -n test-namespace-001 --ignore-not-found
  sleep 5
  kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001 && echo "Iteration $i: SA exists" || echo "Iteration $i: SA missing"
  kubectl annotate permissionbinder test-sa-recreation -n permissions-binder-operator stress-test="iteration-$i" --overwrite
  sleep 10
done

# Final verification
kubectl get sa test-namespace-001-sa-recreation-test -n test-namespace-001 && echo "PASS: SA survives stress test" || echo "FAIL: SA missing after stress test"
```

**Expected Result**:
- ✅ Operator detects ServiceAccount deletion
- ✅ ServiceAccount automatically recreated
- ✅ New UID confirms new instance
- ✅ RoleBinding updated to reference new SA
- ✅ New token/secret created
- ✅ Recreation logged in JSON logs
- ✅ Survives multiple rapid deletions
- ✅ Eventual consistency achieved

**Log Verification**:
```bash
# Expected log entries
{
  "level": "info",
  "message": "ServiceAccount not found, creating",
  "action": "create_serviceaccount",
  "namespace": "test-namespace-001",
  "serviceAccount": "test-namespace-001-sa-recreation-test",
  "reason": "missing_resource"
}
```

---

