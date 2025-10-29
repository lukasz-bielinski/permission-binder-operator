# E2E Test Scenarios for Permission Binder Operator

## Test Suite Overview
This document contains **35 comprehensive end-to-end test scenarios** (Pre-Test + Tests 1-34) for the Permission Binder Operator to ensure it behaves correctly in all situations.

## Prerequisites
- K3s cluster with mixed architectures (ARM64 and AMD64)
- Operator deployed in `permissions-binder-operator` namespace
- Docker images pushed to `lukaszbielinski/permission-binder-operator:latest`
- Prometheus installed and running in `monitoring` namespace
- ServiceMonitor configured for operator metrics collection

## Test Scenarios

### Pre-Test: Initial State Verification
**Objective**: Verify operator is running and basic functionality works before starting tests
**Steps**:
1. Check operator pod is running
2. Verify JSON structured logging is working
3. Verify finalizer is present on PermissionBinder CR
4. Confirm operator deployment is healthy

**Expected Result**: Operator is running and healthy, ready for testing

**Note**: This is a sanity check performed before the main test suite.

---

### Test 1: Role Mapping Changes
**Objective**: Verify operator correctly handles changes in role mapping
**Steps**:
1. Create new ClusterRole (e.g., `clusterrole-developer`)
2. Add new role to PermissionBinder mapping
3. Verify operator creates RoleBindings for new role in all managed namespaces
4. Verify RoleBindings have correct ClusterRole reference

**Expected Result**: 6 new RoleBindings created (1 role × 6 namespaces)

### Test 2: Prefix Changes
**Objective**: Verify operator handles prefix changes correctly
**Steps**:
1. Change prefix from `COMPANY-K8S` to `NEW_PREFIX`
2. Add new ConfigMap entry with new prefix
3. Verify operator processes new prefix correctly
4. Verify old RoleBindings with old prefix are removed
5. Verify new RoleBindings with new prefix are created

**Expected Result**: Old RoleBindings removed, new ones created with correct prefix

### Test 3: Exclude List Changes
**Objective**: Verify operator respects exclude list changes
**Steps**:
1. Add new entry to exclude list
2. Add corresponding entry to ConfigMap
3. Verify operator skips excluded entries
4. Remove entry from exclude list
5. Verify operator now processes the entry

**Expected Result**: Excluded entries are ignored, non-excluded entries are processed

### Test 4: ConfigMap Changes - Addition
**Objective**: Verify operator processes new ConfigMap entries
**Steps**:
1. Add new entry to ConfigMap with valid format
2. Verify operator creates corresponding RoleBinding
3. Verify namespace is created if it doesn't exist
4. Verify RoleBinding has correct annotations and labels

**Expected Result**: New RoleBinding created with proper metadata

### Test 5: ConfigMap Changes - Removal
**Objective**: Verify operator handles ConfigMap entry removal
**Steps**:
1. Remove entry from ConfigMap
2. Verify corresponding RoleBinding is removed
3. Verify namespace is NOT deleted (only annotated)

**Expected Result**: RoleBinding removed, namespace preserved with annotation

### Test 6: Role Removal from Mapping
**Objective**: Verify operator removes RoleBindings when role is removed from mapping
**Steps**:
1. Remove role from PermissionBinder mapping
2. Verify all RoleBindings for that role are deleted
3. Verify other RoleBindings remain intact

**Expected Result**: RoleBindings for removed role deleted, others preserved

### Test 7: Namespace Protection
**Objective**: Verify operator NEVER deletes namespaces
**Steps**:
1. Create namespace with operator
2. Remove all ConfigMap entries for that namespace
3. Verify namespace is NOT deleted
4. Verify namespace has annotation indicating operator wanted to remove it

**Expected Result**: Namespace preserved with removal annotation

### Test 8: PermissionBinder Deletion (SAFE MODE)
**Objective**: Verify operator does NOT delete RoleBindings when PermissionBinder is deleted
**Steps**:
1. Delete PermissionBinder resource
2. Verify all RoleBindings remain intact
3. Verify namespaces remain intact
4. Verify only operator deployment is removed

**Expected Result**: All managed resources preserved (SAFE MODE)

### Test 9: Operator Restart Recovery
**Objective**: Verify operator recovers state after restart
**Steps**:
1. Restart operator deployment
2. Verify operator reads current state
3. Verify no duplicate resources are created
4. Verify all existing RoleBindings are recognized

**Expected Result**: Operator recovers without creating duplicates

### Test 10: Conflict Handling
**Objective**: Verify operator handles naming conflicts gracefully
**Steps**:
1. Add duplicate entries to ConfigMap
2. Verify operator handles duplicates correctly
3. Verify no errors occur in operator logs

**Expected Result**: Operator handles conflicts gracefully

### Test 11: Invalid Configuration Handling
**Objective**: Verify operator handles invalid configurations gracefully
**Steps**:
1. Add invalid entry to ConfigMap (wrong format)
2. Verify operator logs error but continues processing
3. Verify valid entries are still processed

**Expected Result**: Invalid entries logged, valid entries processed

### Test 12: Multi-Architecture Verification
**Objective**: Verify operator works on both ARM64 and AMD64 nodes
**Steps**:
1. Check operator pod is running on correct architecture
2. Verify operator functionality on both architectures
3. Verify no architecture-specific issues

**Expected Result**: Operator works correctly on both architectures

### Test 13: Non-Existent ClusterRole (Security)
**Objective**: Verify operator handles missing ClusterRoles safely
**Steps**:
1. Add role to PermissionBinder mapping that references non-existent ClusterRole
2. Add corresponding entry to ConfigMap
3. Verify operator creates RoleBinding despite missing ClusterRole
4. Verify WARNING is logged with security_impact=high
5. Verify JSON log contains: clusterRole, severity, action_required, impact
6. Create the ClusterRole later and verify RoleBinding starts working

**Expected Result**: RoleBinding created, clear WARNING logged, no reconciliation failure

### Test 14: Orphaned Resources Adoption
**Objective**: Verify automatic adoption of orphaned resources
**Steps**:
1. Create PermissionBinder and verify resources are created
2. Delete PermissionBinder (SAFE MODE - resources get orphaned annotations)
3. Verify resources have `orphaned-at` and `orphaned-by` annotations
4. Recreate the same PermissionBinder (same name/namespace)
5. Verify operator automatically removes orphaned annotations
6. Verify adoption is logged with action=adoption, recovery=automatic
7. Verify resources are fully managed again

**Expected Result**: Orphaned resources automatically adopted, zero data loss

### Test 15: Manual RoleBinding Modification (Protection)
**Objective**: Verify operator overrides manual changes
**Steps**:
1. Create RoleBinding via operator
2. Manually edit RoleBinding (change subjects or roleRef)
3. Wait for reconciliation
4. Verify operator restores RoleBinding to desired state
5. Verify no manual changes persist

**Expected Result**: Operator enforces desired state, manual changes overridden

### Test 16: Operator Permission Loss (Security)
**Objective**: Verify behavior when operator loses RBAC permissions
**Steps**:
1. Remove specific RBAC permission from operator ServiceAccount (e.g., rolebindings.create)
2. Trigger reconciliation (add ConfigMap entry)
3. Verify operator logs ERROR with proper context
4. Verify JSON logs are parseable and contain error details
5. Restore permissions
6. Verify operator recovers and creates pending resources

**Expected Result**: Clear error logging, graceful degradation, automatic recovery

### Test 17: Partial Failure Recovery (Reliability)
**Objective**: Verify operator recovers from partial failures
**Steps**:
1. Add multiple entries to ConfigMap simultaneously
2. Make one entry invalid (e.g., non-existent ClusterRole that causes K8s rejection)
3. Verify operator processes valid entries successfully
4. Verify invalid entry is logged as ERROR
5. Verify partial success doesn't block other operations
6. Fix invalid entry and verify it gets processed

**Expected Result**: Partial failures don't cascade, valid operations succeed

### Test 18: JSON Structured Logging Verification (Audit)
**Objective**: Verify all logs are valid JSON for SIEM ingestion
**Steps**:
1. Perform various operations (create, update, delete, errors)
2. Extract operator logs
3. Verify every log line is valid JSON
4. Verify JSON contains required fields: timestamp, level, message
5. Verify security events have severity field
6. Verify all operations have action/namespace/resource context
7. Test log parsing with jq or similar JSON tool

**Expected Result**: 100% of logs are valid, parseable JSON with required fields

### Test 19: Concurrent ConfigMap Changes (Race Conditions)
**Objective**: Verify operator handles rapid changes safely
**Steps**:
1. Add multiple entries to ConfigMap in quick succession (< 1 second apart)
2. Modify PermissionBinder while ConfigMap is changing
3. Verify operator doesn't create duplicate resources
4. Verify final state is consistent with latest configuration
5. Check for any race condition errors in logs

**Expected Result**: No duplicates, no inconsistencies, eventual consistency achieved

### Test 20: ConfigMap Corruption Handling
**Objective**: Verify operator handles malformed ConfigMap data
**Steps**:
1. Add ConfigMap entry with incorrect format (missing parts)
2. Add entry with special characters that could break parsing
3. Add entry with very long string (> 253 chars for namespace)
4. Verify operator logs ERROR for each invalid entry
5. Verify operator continues processing valid entries
6. Verify no operator crash or restart

**Expected Result**: Graceful error handling, no crash, valid entries processed

### Test 21: Network Failure Simulation
**Objective**: Verify operator handles temporary network issues
**Steps**:
1. Simulate network partition (if possible in test environment)
2. Or, scale API server pods down temporarily
3. Trigger reconciliation during network issue
4. Verify operator logs connection errors
5. Restore network/API server
6. Verify operator automatically recovers and reconciles

**Expected Result**: Graceful degradation, automatic recovery, no stuck state

### Test 22: Metrics Endpoint Verification
**Objective**: Verify Prometheus metrics are exposed correctly
**Steps**:
1. Access operator metrics endpoint (https://operator-pod:8443/metrics)
2. Verify metrics endpoint requires authentication
3. Verify metrics contain controller-runtime standard metrics
4. Verify metrics are in Prometheus format
5. Check for useful metrics: reconciliation time, error rate, etc.

**Expected Result**: Metrics accessible, secured, properly formatted

### Test 23: Finalizer Behavior Verification
**Objective**: Verify finalizer ensures proper cleanup sequence
**Steps**:
1. Create PermissionBinder and verify finalizer is added
2. Initiate deletion (kubectl delete)
3. Verify PermissionBinder enters "Terminating" state
4. Verify cleanup logic executes (orphaned annotations added)
5. Verify finalizer is removed after cleanup
6. Verify PermissionBinder is fully deleted

**Expected Result**: Proper cleanup sequence, no stuck finalizers

### Test 24: Large ConfigMap Handling
**Objective**: Verify operator handles ConfigMaps with many entries
**Steps**:
1. Create ConfigMap with 50+ entries
2. Verify operator processes all entries
3. Monitor operator memory and CPU usage
4. Verify reconciliation completes successfully
5. Check reconciliation time is acceptable (< 30 seconds)

**Expected Result**: All entries processed, acceptable performance, no OOM

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

### Test 27: Metrics Update on ConfigMap Changes
**Objective**: Verify metrics update when ConfigMap changes
**Steps**:
1. Record initial `permission_binder_managed_namespaces_total` value
2. Add new namespace entry to ConfigMap
3. Wait for operator reconciliation
4. Check updated metric value
5. Verify increase matches expected number of new namespaces

**Expected Result**: Namespace metrics reflect actual managed namespaces

### Test 28: Orphaned Resources Metrics
**Objective**: Verify orphaned resources are tracked in metrics
**Steps**:
1. Record initial `permission_binder_orphaned_resources_total` value
2. Delete PermissionBinder CR (triggers SAFE MODE)
3. Wait for operator cleanup
4. Check updated metric value
5. Verify increase matches expected number of orphaned resources

**Expected Result**: Orphaned resources are properly tracked

### Test 29: ConfigMap Processing Metrics
**Objective**: Verify ConfigMap processing is tracked in metrics
**Steps**:
1. Query `permission_binder_configmap_entries_processed_total` metric
2. Add new entry to ConfigMap
3. Wait for operator processing
4. Check updated metric value
5. Verify increase matches expected number of processed entries

**Expected Result**: ConfigMap processing is properly tracked

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

## Test 31: ServiceAccount Creation

**Objective**: Verify basic ServiceAccount creation and RoleBinding

**Setup**:
```bash
# Create PermissionBinder with SA mapping
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-basic
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: edit
    runtime: view
EOF
```

**Execution**:
```bash
# Wait for reconciliation
sleep 5

# Verify ServiceAccounts created
kubectl get sa -n test-namespace-001 | grep "sa-deploy"
kubectl get sa -n test-namespace-001 | grep "sa-runtime"

# Verify RoleBindings created
kubectl get rolebinding -n test-namespace-001 | grep "sa-deploy"
kubectl get rolebinding -n test-namespace-001 | grep "sa-runtime"
```

**Expected Result**:
- ServiceAccounts `test-namespace-001-sa-deploy` and `test-namespace-001-sa-runtime` exist
- RoleBindings created for both ServiceAccounts
- deploy SA has edit role, runtime SA has view role

---

## Test 32: ServiceAccount Naming Pattern

**Objective**: Verify custom naming pattern works correctly

**Setup**:
```bash
# Create PermissionBinder with custom pattern
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-pattern
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: edit
  serviceAccountNamingPattern: "sa-{namespace}-{name}"
EOF
```

**Execution**:
```bash
# Wait for reconciliation
sleep 5

# Verify SA with custom pattern
kubectl get sa -n test-namespace-001 sa-test-namespace-001-deploy
```

**Expected Result**:
- ServiceAccount named `sa-test-namespace-001-deploy` exists
- Pattern `sa-{namespace}-{name}` correctly applied

---

## Test 33: ServiceAccount Idempotency

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

## Test 34: ServiceAccount Status Tracking

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

