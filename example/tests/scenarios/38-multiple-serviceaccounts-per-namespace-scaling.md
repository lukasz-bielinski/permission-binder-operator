### Test 38: Multiple ServiceAccounts per Namespace (Scaling)

**Objective**: Verify operator handles multiple ServiceAccounts in same namespace efficiently

**Background**:
A namespace may need multiple ServiceAccounts for different purposes (deploy, runtime, monitoring, ci/cd). The operator should handle many SAs per namespace without performance degradation.

**Setup**:
```bash
# Create PermissionBinder with multiple ServiceAccount mappings
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-multiple
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: admin
    runtime: view
    monitoring: view
    cicd: edit
    backup: edit
    logging: view
    metrics: view
    ingress: edit
EOF

# Record start time
START_TIME=$(date +%s)
```

**Execution**:
```bash
# Wait for reconciliation
sleep 20

# Record end time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "Reconciliation duration: ${DURATION}s"

# Step 1: Verify all 8 ServiceAccounts created
EXPECTED_SA_COUNT=8
ACTUAL_SA_COUNT=$(kubectl get sa -n test-namespace-001 | grep "sa-" | wc -l)

echo "Expected ServiceAccounts: $EXPECTED_SA_COUNT"
echo "Actual ServiceAccounts: $ACTUAL_SA_COUNT"

if [ $ACTUAL_SA_COUNT -ge $EXPECTED_SA_COUNT ]; then
  echo "PASS: All ServiceAccounts created"
else
  echo "FAIL: Missing ServiceAccounts (expected $EXPECTED_SA_COUNT, got $ACTUAL_SA_COUNT)"
fi

# Step 2: Verify all RoleBindings created
EXPECTED_RB_COUNT=8
ACTUAL_RB_COUNT=$(kubectl get rolebinding -n test-namespace-001 -o json | jq '[.items[] | select(.subjects[0].kind == "ServiceAccount")] | length')

echo "Expected RoleBindings for SAs: $EXPECTED_RB_COUNT"
echo "Actual RoleBindings for SAs: $ACTUAL_RB_COUNT"

if [ $ACTUAL_RB_COUNT -ge $EXPECTED_RB_COUNT ]; then
  echo "PASS: All RoleBindings created"
else
  echo "FAIL: Missing RoleBindings (expected $EXPECTED_RB_COUNT, got $ACTUAL_RB_COUNT)"
fi

# Step 3: Verify each SA has correct role
kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].kind == "ServiceAccount") | "\(.subjects[0].name) -> \(.roleRef.name)"' | sort

# Step 4: Verify no duplicates
DUPLICATE_CHECK=$(kubectl get sa -n test-namespace-001 -o json | jq -r '[.items[].metadata.name] | group_by(.) | map(select(length > 1)) | length')

if [ "$DUPLICATE_CHECK" == "0" ]; then
  echo "PASS: No duplicate ServiceAccounts"
else
  echo "FAIL: Duplicate ServiceAccounts detected"
fi

# Step 5: Performance check - reconciliation should be fast
if [ $DURATION -lt 30 ]; then
  echo "PASS: Reconciliation completed in acceptable time (${DURATION}s < 30s)"
else
  echo "WARN: Reconciliation took longer than expected (${DURATION}s)"
fi

# Step 6: Memory usage check
POD_NAME=$(kubectl get pod -n permissions-binder-operator -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}')
MEMORY_USAGE=$(kubectl top pod $POD_NAME -n permissions-binder-operator --no-headers | awk '{print $3}')

echo "Operator memory usage: $MEMORY_USAGE"

# Step 7: Verify status tracking
SA_STATUS_COUNT=$(kubectl get permissionbinder test-sa-multiple -n permissions-binder-operator -o jsonpath='{.status.processedServiceAccounts}' | jq '. | length')

echo "ServiceAccounts tracked in status: $SA_STATUS_COUNT"

if [ $SA_STATUS_COUNT -ge $EXPECTED_SA_COUNT ]; then
  echo "PASS: All ServiceAccounts tracked in status"
else
  echo "FAIL: Status missing ServiceAccounts"
fi
```

**Expected Result**:
- ✅ All 8 ServiceAccounts created successfully
- ✅ All 8 RoleBindings created with correct roles
- ✅ No duplicates
- ✅ Reconciliation < 30 seconds
- ✅ Memory usage acceptable (< 200Mi)
- ✅ Status correctly tracks all SAs
- ✅ No resource conflicts

**Performance Benchmarks**:
- 8 SAs per namespace: < 30s
- Expected memory: < 150Mi
- No errors in logs

---

