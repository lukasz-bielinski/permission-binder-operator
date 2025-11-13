### Test 25: Prometheus Metrics Collection
**Objective**: Verify Prometheus collects operator metrics correctly
**Steps**:
1. Check Prometheus target status for operator
2. Query `permission_binder_managed_rolebindings_total` metric
3. Query `permission_binder_managed_namespaces_total` metric
4. Query `permission_binder_orphaned_resources_total` metric
5. Verify metrics have correct labels and values

**Expected Result**: All custom metrics are collected with correct values

**Commands**:
```bash
# Check target status
kubectl exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -- wget -q -O- "http://localhost:9090/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job=="operator-controller-manager-metrics-service")'

# Query metrics
kubectl exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" | jq '.data.result[0].value[1]'
```

