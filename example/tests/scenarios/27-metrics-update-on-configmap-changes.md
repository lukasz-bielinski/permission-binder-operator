### Test 27: Metrics Update on ConfigMap Changes
**Objective**: Verify metrics update when ConfigMap changes
**Steps**:
1. Record initial `permission_binder_managed_namespaces_total` value
2. Add new namespace entry to ConfigMap
3. Wait for operator reconciliation
4. Check updated metric value
5. Verify increase matches expected number of new namespaces

**Expected Result**: Namespace metrics reflect actual managed namespaces

