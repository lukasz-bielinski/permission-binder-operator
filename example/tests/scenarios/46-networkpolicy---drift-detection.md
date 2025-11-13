### Test 46: NetworkPolicy - Drift Detection

**Objective**: Verify operator detects drift in periodic reconciliation

**Execution**:
```bash
# Wait for periodic reconciliation (up to 90s, or wait for reconciliationInterval: 1h)
# Check for lastNetworkPolicyReconciliation timestamp
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.lastNetworkPolicyReconciliation}'
```

**Expected Result**:
- ✅ `lastNetworkPolicyReconciliation` timestamp updated in PermissionBinder status
- ✅ Periodic reconciliation runs at configured interval (1h)
- ✅ Drift detection checks Git repository vs Kubernetes cluster state

**Note**: In real scenario, this test requires waiting for `reconciliationInterval` (1h). Test waits up to 90s for initial reconciliation.

---

