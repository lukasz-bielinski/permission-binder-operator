### Test 30: Adoption Events Metrics
**Objective**: Verify adoption events are tracked in metrics
**Steps**:
1. Record initial `permission_binder_adoption_events_total` value
2. Recreate PermissionBinder CR (triggers adoption)
3. Wait for operator adoption
4. Check updated metric value
5. Verify increase matches expected number of adoption events

**Expected Result**: Adoption events are properly tracked

## Test Execution Commands

### Setup
```bash
export KUBECONFIG=$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)
cd example
kubectl apply -k .
```

### Cleanup
```bash
export KUBECONFIG=$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)
kubectl delete -k .
```

### Monitoring
```bash
# Watch operator logs (JSON formatted)
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager -f

# Parse JSON logs with jq
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | jq '.'

# Filter ERROR logs
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | jq 'select(.level=="error")'

# Filter WARNING logs (security critical)
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | jq 'select(.severity=="warning")'

# Check RoleBindings
kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator

# Check namespaces
kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator

# Check for orphaned resources
kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"] != null)'

# Access operator metrics (HTTP, no auth required)
kubectl port-forward -n permissions-binder-operator svc/operator-controller-manager-metrics-service 8080:8080
curl http://localhost:8080/metrics

# Access Prometheus metrics
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Query operator metrics from Prometheus
kubectl exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" | jq '.data.result[0].value[1]'

# Check Prometheus targets
kubectl exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -- wget -q -O- "http://localhost:9090/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job=="operator-controller-manager-metrics-service")'
```

## Success Criteria

### Functional Requirements
- ✅ All tests pass without errors
- ✅ No cascade failures occur
- ✅ Operator maintains data integrity
- ✅ Safe mode prevents accidental deletions
- ✅ Multi-architecture support works correctly
- ✅ Orphaned resources automatically adopted on recovery

### Production-Grade Requirements
- ✅ **JSON Logging**: 100% of logs are valid JSON
- ✅ **Audit Trail**: All operations logged with full context
- ✅ **Security Warnings**: ClusterRole validation with clear alerts
- ✅ **Predictability**: Operator enforces desired state (overrides manual changes)
- ✅ **Reliability**: Graceful degradation on failures
- ✅ **Recovery**: Automatic recovery from transient failures
- ✅ **No Data Loss**: SAFE MODE prevents accidental resource deletion
- ✅ **Observability**: Prometheus metrics exposed
- ✅ **Error Handling**: Partial failures don't cascade

### Security Requirements
- ✅ ClusterRole existence validation before granting permissions
- ✅ All security events logged with `severity` field
- ✅ RBAC permission loss handled gracefully
- ✅ No privilege escalation possible
- ✅ Metrics endpoint secured with authentication

### Compliance Requirements
- ✅ Structured logging for SIEM integration
- ✅ Audit trail with timestamps and actors
- ✅ Immutable desired state enforcement
- ✅ Clear error messages for troubleshooting
- ✅ Metrics for SLA monitoring

## Production Environment Specific Notes

### Log Retention
- JSON logs should be forwarded to centralized logging (ELK, Splunk, etc.)
- Recommended retention: minimum 90 days for compliance
- Logs contain sensitive namespace/role information - ensure proper access controls

### Monitoring Alerts
Recommended Prometheus alerts:
```yaml
# High rate of ClusterRole validation failures
- alert: MissingClusterRoles
  expr: rate(permission_binder_missing_clusterrole_total[5m]) > 0.1
  severity: warning

# Orphaned resources detected
- alert: OrphanedResourcesDetected
  expr: permission_binder_orphaned_resources_total > 0
  severity: info

# Reconciliation errors
- alert: ReconciliationErrors
  expr: rate(permission_binder_reconciliation_errors_total[5m]) > 0.5
  severity: critical
```

### Disaster Recovery
1. **Backup**: Export all PermissionBinder CRs regularly
   ```bash
   kubectl get permissionbinders -A -o yaml > backup-permissionbinders.yaml
   ```

2. **Recovery**: Recreate PermissionBinder CRs
   - Operator will automatically adopt orphaned resources
   - Zero downtime, zero data loss

3. **Validation**: After recovery, verify all resources are adopted
   ```bash
   # Should return no results after adoption
   kubectl get rolebindings -A -o json | jq '.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"] != null)'
   ```

### Change Management
1. **Testing**: Always test changes in non-production first
2. **Rollback**: Keep previous PermissionBinder CR versions in git
3. **Gradual Rollout**: Change one namespace at a time if possible
4. **Verification**: After changes, verify logs for warnings/errors

### Troubleshooting
Common issues and solutions:

1. **Missing ClusterRole**:
   - Check logs: `jq 'select(.severity=="warning" and .clusterRole)'`
   - Create missing ClusterRole
   - RoleBinding will automatically start working

2. **Orphaned Resources**:
   - List orphaned: `kubectl get rolebindings -A -o json | jq '.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])'`
   - Recreate PermissionBinder with same name
   - Verify adoption in logs

3. **Permission Denied**:
   - Check ServiceAccount RBAC permissions
   - Verify ClusterRoleBinding for operator
   - Check logs for specific permission errors

---

