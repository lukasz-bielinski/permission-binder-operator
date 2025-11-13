### Test 33: ServiceAccount Idempotency

**Objective**: Verify ServiceAccount creation is idempotent

**Execution**:
```bash
# Record current ServiceAccount UID
SA_UID=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.uid}')

# Trigger reconciliation by updating ConfigMap
kubectl annotate configmap permission-config -n permissions-binder-operator test-reconcile="$(date +%s)" --overwrite

# Wait for reconciliation
sleep 5

# Verify SA UID unchanged (not recreated)
NEW_SA_UID=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.uid}')

if [ "$SA_UID" == "$NEW_SA_UID" ]; then
  echo "PASS: ServiceAccount not recreated (idempotent)"
else
  echo "FAIL: ServiceAccount was recreated"
fi
```

**Expected Result**:
- ServiceAccount UID unchanged
- No unnecessary recreation

---

