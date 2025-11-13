### Test 34: ServiceAccount Status Tracking

**Objective**: Verify processed ServiceAccounts tracked in status

**Execution**:
```bash
# Check PermissionBinder status
kubectl get permissionbinder test-sa-basic -n permissions-binder-operator -o jsonpath='{.status.processedServiceAccounts}' | jq .

# Verify ServiceAccounts listed
SA_COUNT=$(kubectl get permissionbinder test-sa-basic -n permissions-binder-operator -o jsonpath='{.status.processedServiceAccounts}' | jq '. | length')

echo "Processed ServiceAccounts: $SA_COUNT"
```

**Expected Result**:
- Status contains list of processed ServiceAccounts
- Format: `namespace/sa-name`
- Example: `["test-namespace-001/test-namespace-001-sa-deploy", "test-namespace-001/test-namespace-001-sa-runtime"]`

---

