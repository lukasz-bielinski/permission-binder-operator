### Test 26: Metrics Update on Role Mapping Changes
**Objective**: Verify metrics update when role mapping changes
**Steps**:
1. Record initial `permission_binder_managed_rolebindings_total` value
2. Add new role to PermissionBinder mapping
3. Wait for operator reconciliation
4. Check updated metric value
5. Verify increase matches expected number of new RoleBindings

**Expected Result**: Metrics reflect actual managed resource counts

**Commands**:
```bash
# Before change
BEFORE=$(kubectl exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" | jq -r '.data.result[0].value[1]')
echo "Before: $BEFORE RoleBindings"

# After change
AFTER=$(kubectl exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" | jq -r '.data.result[0].value[1]')
echo "After: $AFTER RoleBindings"
echo "Increase: $((AFTER - BEFORE))"
```

