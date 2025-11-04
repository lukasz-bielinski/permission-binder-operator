# E2E Test Scenarios for Permission Binder Operator

## Test Suite Overview
This document contains **43 comprehensive end-to-end test scenarios** (Pre-Test + Tests 1-43) for the Permission Binder Operator to ensure it behaves correctly in all situations.

**Test Categories:**
- **Basic Functionality (Tests 1-11)**: Core operator features, role mapping, prefixes, ConfigMap handling
- **Security & Reliability (Tests 12-24)**: Security validation, error handling, observability
- **Metrics & Monitoring (Tests 25-30)**: Prometheus metrics, metrics updates
- **ServiceAccount Management (Tests 31-41)**: ServiceAccount creation, protection, updates
- **Bug Fixes (Tests 42-43)**: RoleBindings with hyphenated roles, invalid whitelist entry handling

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

### Test 31: ServiceAccount Creation

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

### Test 32: ServiceAccount Naming Pattern

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

### Test 35: ServiceAccount Protection (SAFE MODE)

**Objective**: Verify operator NEVER deletes ServiceAccounts it created

**Background**: 
Similar to namespace protection (Test 7), ServiceAccounts should never be deleted by the operator. This prevents service disruptions and maintains security tokens/secrets. When a ServiceAccount is no longer needed, it should be marked with an annotation, not deleted.

**Setup**:
```bash
# Create PermissionBinder with ServiceAccount mapping
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-protection
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

# Wait for ServiceAccounts to be created
sleep 10

# Verify ServiceAccounts exist
kubectl get sa -n test-namespace-001 | grep "sa-deploy"
kubectl get sa -n test-namespace-001 | grep "sa-runtime"
```

**Execution**:
```bash
# Step 1: Record ServiceAccount UIDs
SA_DEPLOY_UID=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.uid}')
SA_RUNTIME_UID=$(kubectl get sa test-namespace-001-sa-runtime -n test-namespace-001 -o jsonpath='{.metadata.uid}')

echo "Deploy SA UID: $SA_DEPLOY_UID"
echo "Runtime SA UID: $SA_RUNTIME_UID"

# Step 2: Remove ServiceAccount mapping from PermissionBinder
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-protection
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping: {}  # REMOVED ALL ServiceAccounts
EOF

# Wait for reconciliation
sleep 10

# Step 3: Verify ServiceAccounts still exist
kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 || echo "FAIL: SA was deleted!"
kubectl get sa test-namespace-001-sa-runtime -n test-namespace-001 || echo "FAIL: SA was deleted!"

# Step 4: Verify UIDs unchanged (not recreated)
NEW_SA_DEPLOY_UID=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.uid}')
NEW_SA_RUNTIME_UID=$(kubectl get sa test-namespace-001-sa-runtime -n test-namespace-001 -o jsonpath='{.metadata.uid}')

if [ "$SA_DEPLOY_UID" == "$NEW_SA_DEPLOY_UID" ]; then
  echo "PASS: Deploy SA preserved (UID unchanged)"
else
  echo "FAIL: Deploy SA was recreated or deleted"
fi

if [ "$SA_RUNTIME_UID" == "$NEW_SA_RUNTIME_UID" ]; then
  echo "PASS: Runtime SA preserved (UID unchanged)"
else
  echo "FAIL: Runtime SA was recreated or deleted"
fi

# Step 5: Verify orphaned annotation added
DEPLOY_ANNOTATION=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.annotations.permission-binder\.io/orphaned-at}')
RUNTIME_ANNOTATION=$(kubectl get sa test-namespace-001-sa-runtime -n test-namespace-001 -o jsonpath='{.metadata.annotations.permission-binder\.io/orphaned-at}')

if [ -n "$DEPLOY_ANNOTATION" ]; then
  echo "PASS: Deploy SA has orphaned-at annotation: $DEPLOY_ANNOTATION"
else
  echo "FAIL: Deploy SA missing orphaned-at annotation"
fi

if [ -n "$RUNTIME_ANNOTATION" ]; then
  echo "PASS: Runtime SA has orphaned-at annotation: $RUNTIME_ANNOTATION"
else
  echo "FAIL: Runtime SA missing orphaned-at annotation"
fi

# Step 6: Verify associated RoleBindings removed
kubectl get rolebinding -n test-namespace-001 | grep "sa-deploy" && echo "WARN: RoleBinding still exists" || echo "PASS: RoleBinding removed"
kubectl get rolebinding -n test-namespace-001 | grep "sa-runtime" && echo "WARN: RoleBinding still exists" || echo "PASS: RoleBinding removed"
```

**Expected Result**:
- ✅ ServiceAccounts NEVER deleted (SAFE MODE)
- ✅ ServiceAccount UIDs unchanged (not recreated)
- ✅ Orphaned annotation added: `permission-binder.io/orphaned-at=<timestamp>`
- ✅ Orphaned annotation added: `permission-binder.io/orphaned-by=<permissionbinder-name>`
- ✅ Associated RoleBindings removed (only bindings, not SAs)
- ✅ ServiceAccounts remain functional (tokens/secrets preserved)

**Security Rationale**:
1. **Token Preservation**: ServiceAccount tokens/secrets must not be invalidated
2. **Pod Continuity**: Running pods using these SAs should not be disrupted
3. **Manual Cleanup**: Admin can manually delete SAs when ready
4. **Audit Trail**: Orphaned annotation provides clear history

**Recovery Test**:
```bash
# Step 7: Re-add ServiceAccount mapping
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-protection
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

# Wait for reconciliation
sleep 10

# Step 8: Verify orphaned annotation removed (adoption)
DEPLOY_ANNOTATION=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.annotations.permission-binder\.io/orphaned-at}')
RUNTIME_ANNOTATION=$(kubectl get sa test-namespace-001-sa-runtime -n test-namespace-001 -o jsonpath='{.metadata.annotations.permission-binder\.io/orphaned-at}')

if [ -z "$DEPLOY_ANNOTATION" ]; then
  echo "PASS: Deploy SA orphaned-at annotation removed (adopted)"
else
  echo "FAIL: Deploy SA still has orphaned-at annotation"
fi

if [ -z "$RUNTIME_ANNOTATION" ]; then
  echo "PASS: Runtime SA orphaned-at annotation removed (adopted)"
else
  echo "FAIL: Runtime SA still has orphaned-at annotation"
fi

# Step 9: Verify RoleBindings recreated
kubectl get rolebinding -n test-namespace-001 | grep "sa-deploy" || echo "FAIL: RoleBinding not recreated"
kubectl get rolebinding -n test-namespace-001 | grep "sa-runtime" || echo "FAIL: RoleBinding not recreated"
```

**Expected Recovery Result**:
- ✅ ServiceAccounts automatically adopted (orphaned annotations removed)
- ✅ RoleBindings recreated
- ✅ Full functionality restored
- ✅ Zero downtime for existing pods using these SAs

**Related Tests**:
- Test 7: Namespace Protection (similar SAFE MODE behavior)
- Test 8: PermissionBinder Deletion (SAFE MODE for all resources)
- Test 14: Orphaned Resources Adoption (automatic recovery)

---

### Test 36: ServiceAccount Deletion and Cleanup (Orphaned RoleBindings)

**Objective**: Verify operator cleans up orphaned RoleBindings when ServiceAccount is manually deleted

**Background**:
When a ServiceAccount is manually deleted (e.g., by admin), any RoleBindings referencing it become orphaned and non-functional. The operator should detect this and clean up orphaned RoleBindings.

**Setup**:
```bash
# Create PermissionBinder with ServiceAccount mapping
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-cleanup
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    cleanup-test: edit
EOF

# Wait for SA and RoleBinding creation
sleep 10

# Verify SA and RoleBinding exist
kubectl get sa test-namespace-001-sa-cleanup-test -n test-namespace-001
kubectl get rolebinding -n test-namespace-001 | grep "sa-cleanup-test"
```

**Execution**:
```bash
# Step 1: Record RoleBinding name
RB_NAME=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-cleanup-test")) | .metadata.name')
echo "RoleBinding: $RB_NAME"

# Step 2: Manually delete ServiceAccount (simulating manual cleanup)
kubectl delete sa test-namespace-001-sa-cleanup-test -n test-namespace-001

# Verify SA deleted
kubectl get sa test-namespace-001-sa-cleanup-test -n test-namespace-001 2>&1 | grep "NotFound" && echo "SA deleted successfully"

# Step 3: Trigger reconciliation (add annotation to PermissionBinder)
kubectl annotate permissionbinder test-sa-cleanup -n permissions-binder-operator trigger-reconcile="$(date +%s)" --overwrite

# Wait for operator to reconcile
sleep 15

# Step 4: Verify orphaned RoleBinding detected and cleaned up
kubectl get rolebinding $RB_NAME -n test-namespace-001 2>&1 | grep "NotFound" && echo "PASS: Orphaned RoleBinding cleaned up" || echo "FAIL: Orphaned RoleBinding still exists"

# Step 5: Verify operator logs cleanup event
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=50 | jq 'select(.message | contains("orphaned") or contains("cleanup"))'

# Step 6: Verify ServiceAccount recreated (operator should recreate it)
sleep 10
kubectl get sa test-namespace-001-sa-cleanup-test -n test-namespace-001 && echo "PASS: SA recreated by operator" || echo "FAIL: SA not recreated"

# Step 7: Verify new RoleBinding created
kubectl get rolebinding -n test-namespace-001 | grep "sa-cleanup-test" && echo "PASS: RoleBinding recreated" || echo "FAIL: RoleBinding not recreated"
```

**Expected Result**:
- ✅ Operator detects manually deleted ServiceAccount
- ✅ Orphaned RoleBinding cleaned up
- ✅ Operator recreates ServiceAccount (matches desired state)
- ✅ New RoleBinding created for recreated SA
- ✅ JSON logs show cleanup action with context
- ✅ No stuck orphaned resources

**Log Verification**:
```bash
# Expected log entry (JSON)
{
  "level": "info",
  "timestamp": "...",
  "message": "Cleaning up orphaned RoleBinding",
  "action": "cleanup_orphaned_rolebinding",
  "namespace": "test-namespace-001",
  "rolebinding": "...",
  "reason": "ServiceAccount not found",
  "serviceAccount": "test-namespace-001-sa-cleanup-test"
}
```

---

### Test 37: Cross-Namespace ServiceAccount References

**Objective**: Verify ServiceAccounts are created per-namespace and don't cross namespace boundaries

**Background**:
Each namespace should have its own ServiceAccount instances. ServiceAccounts from one namespace cannot be referenced in RoleBindings of another namespace. The operator must create separate SAs per namespace.

**Setup**:
```bash
# Create PermissionBinder with ServiceAccount mapping
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-cross-ns
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    cross-ns-test: view
EOF

# Wait for reconciliation
sleep 10
```

**Execution**:
```bash
# Step 1: Verify SA created in each managed namespace
MANAGED_NAMESPACES=$(kubectl get ns -l permission-binder.io/managed-by=permission-binder-operator -o jsonpath='{.items[*].metadata.name}')

for ns in $MANAGED_NAMESPACES; do
  echo "Checking namespace: $ns"
  
  # Verify SA exists in this namespace
  kubectl get sa ${ns}-sa-cross-ns-test -n $ns && echo "  ✓ SA exists" || echo "  ✗ SA missing"
  
  # Verify RoleBinding references SA from SAME namespace
  RB_SA=$(kubectl get rolebinding -n $ns -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-cross-ns-test")) | .subjects[0].namespace')
  
  if [ "$RB_SA" == "$ns" ]; then
    echo "  ✓ RoleBinding references SA from same namespace"
  else
    echo "  ✗ FAIL: RoleBinding references SA from different namespace: $RB_SA"
  fi
done

# Step 2: Verify SA UIDs are different per namespace (separate instances)
SA_UID_NS1=$(kubectl get sa test-namespace-001-sa-cross-ns-test -n test-namespace-001 -o jsonpath='{.metadata.uid}')
SA_UID_NS2=$(kubectl get sa test-namespace-002-sa-cross-ns-test -n test-namespace-002 -o jsonpath='{.metadata.uid}')

if [ "$SA_UID_NS1" != "$SA_UID_NS2" ]; then
  echo "PASS: ServiceAccounts are separate instances per namespace"
else
  echo "FAIL: ServiceAccounts have same UID (should be different)"
fi

# Step 3: Verify tokens are namespace-specific
TOKEN_NS1=$(kubectl get sa test-namespace-001-sa-cross-ns-test -n test-namespace-001 -o jsonpath='{.secrets[0].name}')
TOKEN_NS2=$(kubectl get sa test-namespace-002-sa-cross-ns-test -n test-namespace-002 -o jsonpath='{.secrets[0].name}')

echo "Token in ns1: $TOKEN_NS1"
echo "Token in ns2: $TOKEN_NS2"

# Step 4: Verify each SA can only access its own namespace
# Create test pod using SA from namespace-001
kubectl run test-pod-sa-ns1 -n test-namespace-001 \
  --image=bitnami/kubectl:latest \
  --serviceaccount=test-namespace-001-sa-cross-ns-test \
  --restart=Never \
  --command -- sleep 3600

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod/test-pod-sa-ns1 -n test-namespace-001 --timeout=60s

# Try to access namespace-002 (should fail - no permissions)
kubectl exec test-pod-sa-ns1 -n test-namespace-001 -- kubectl get pods -n test-namespace-002 2>&1 | grep "Forbidden" && echo "PASS: Cross-namespace access denied" || echo "FAIL: Cross-namespace access allowed"

# Cleanup test pod
kubectl delete pod test-pod-sa-ns1 -n test-namespace-001 --grace-period=0 --force
```

**Expected Result**:
- ✅ ServiceAccount created in each managed namespace
- ✅ Each SA is a separate instance (different UIDs)
- ✅ RoleBindings reference SA from same namespace only
- ✅ Each SA has namespace-specific tokens
- ✅ Cross-namespace access denied (proper isolation)
- ✅ No shared ServiceAccounts across namespaces

**Security Validation**:
- Namespace isolation maintained
- No privilege escalation across namespaces
- Each SA has minimal required permissions

---

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

### Test 39: ServiceAccount Special Characters and Edge Cases

**Objective**: Verify operator handles edge cases in ServiceAccount names and configurations

**Background**:
Kubernetes has strict naming rules. ServiceAccount names must be valid DNS-1123 subdomain names. The operator should validate names and handle edge cases gracefully.

**Test Cases**:

#### Test 39.1: Valid Special Characters (Hyphens)
```bash
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-special-chars
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    my-deploy-sa: edit
    test-runtime-123: view
    sa-with-many-hyphens: view
EOF

sleep 10

# Verify valid names accepted
kubectl get sa -n test-namespace-001 | grep "my-deploy-sa" && echo "PASS: Hyphens supported"
kubectl get sa -n test-namespace-001 | grep "test-runtime-123" && echo "PASS: Numbers supported"
kubectl get sa -n test-namespace-001 | grep "sa-with-many-hyphens" && echo "PASS: Multiple hyphens supported"
```

#### Test 39.2: Invalid Characters (Should be rejected or sanitized)
```bash
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-invalid
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    "UPPERCASE_SA": edit
    "sa.with.dots": view
    "sa_with_underscores": view
EOF

sleep 10

# Check operator logs for validation errors
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=50 | jq 'select(.level=="error" or .level=="warning") | select(.message | contains("invalid") or contains("ServiceAccount"))'

# Verify invalid names rejected (SA not created)
kubectl get sa -n test-namespace-001 | grep "UPPERCASE_SA" && echo "FAIL: Invalid name accepted" || echo "PASS: Invalid name rejected"
```

#### Test 39.3: Name Length Limits
```bash
# Max length for K8s resource name: 253 characters
LONG_NAME="sa-$(printf 'a%.0s' {1..250})"

kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-long-name
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    "${LONG_NAME}": view
EOF

sleep 10

# Check if operator handles long names
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=50 | jq 'select(.message | contains("name too long") or contains("exceeds"))'
```

#### Test 39.4: Empty ServiceAccount Mapping
```bash
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-empty
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping: {}
EOF

sleep 5

# Verify no crash, logs show empty mapping
kubectl get pod -n permissions-binder-operator -l control-plane=controller-manager -o jsonpath='{.items[0].status.phase}' | grep "Running" && echo "PASS: No crash with empty mapping"
```

**Expected Result**:
- ✅ Valid characters (hyphens, numbers) supported
- ✅ Invalid characters (uppercase, dots, underscores) rejected with clear error
- ✅ Name length validation (max 253 chars)
- ✅ Empty mapping handled gracefully
- ✅ Clear JSON logs for validation errors
- ✅ No operator crash on invalid input
- ✅ Valid entries processed even if some are invalid

---

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

### Test 41: ServiceAccount Permission Updates via ConfigMap

**Objective**: Verify ServiceAccount permissions update when role mapping changes in ConfigMap

**Background**:
When role assignments change in the PermissionBinder, existing ServiceAccount RoleBindings should be updated to reflect new permissions. This tests dynamic permission management.

**Setup**:
```bash
# Create PermissionBinder with initial permissions
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-permission-update
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: view  # Start with view (read-only)
    runtime: view
EOF

sleep 10

# Verify initial state
kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-deploy")) | "SA: \(.subjects[0].name) -> Role: \(.roleRef.name)"'
```

**Execution**:
```bash
# Step 1: Record initial permissions
INITIAL_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-deploy")) | .roleRef.name')

echo "Initial role for deploy SA: $INITIAL_ROLE"

if [ "$INITIAL_ROLE" == "view" ]; then
  echo "PASS: Initial role is 'view'"
else
  echo "FAIL: Initial role should be 'view', got: $INITIAL_ROLE"
fi

# Step 2: Update ServiceAccount mapping (upgrade permissions)
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-permission-update
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: admin  # UPGRADED: view -> admin
    runtime: edit  # UPGRADED: view -> edit
EOF

# Wait for reconciliation
sleep 15

# Step 3: Verify permissions updated
NEW_DEPLOY_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-deploy")) | .roleRef.name')
NEW_RUNTIME_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-runtime")) | .roleRef.name')

echo "New role for deploy SA: $NEW_DEPLOY_ROLE"
echo "New role for runtime SA: $NEW_RUNTIME_ROLE"

if [ "$NEW_DEPLOY_ROLE" == "admin" ]; then
  echo "PASS: Deploy SA upgraded to admin"
else
  echo "FAIL: Deploy SA should be admin, got: $NEW_DEPLOY_ROLE"
fi

if [ "$NEW_RUNTIME_ROLE" == "edit" ]; then
  echo "PASS: Runtime SA upgraded to edit"
else
  echo "FAIL: Runtime SA should be edit, got: $NEW_RUNTIME_ROLE"
fi

# Step 4: Verify SA UID unchanged (not recreated)
SA_UID=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.uid}')
echo "ServiceAccount UID: $SA_UID"
# (Compare with initial UID from Step 1 if recorded)

# Step 5: Test permission downgrade
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-permission-update
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: view  # DOWNGRADED: admin -> view
    runtime: view  # DOWNGRADED: edit -> view
EOF

sleep 15

# Step 6: Verify permissions downgraded
FINAL_DEPLOY_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-deploy")) | .roleRef.name')
FINAL_RUNTIME_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-runtime")) | .roleRef.name')

echo "Final role for deploy SA: $FINAL_DEPLOY_ROLE"
echo "Final role for runtime SA: $FINAL_RUNTIME_ROLE"

if [ "$FINAL_DEPLOY_ROLE" == "view" ]; then
  echo "PASS: Deploy SA downgraded to view"
else
  echo "FAIL: Deploy SA should be view, got: $FINAL_DEPLOY_ROLE"
fi

if [ "$FINAL_RUNTIME_ROLE" == "view" ]; then
  echo "PASS: Runtime SA downgraded to view"
else
  echo "FAIL: Runtime SA should be view, got: $FINAL_RUNTIME_ROLE"
fi

# Step 7: Verify operator logs permission changes
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=100 | jq 'select(.message | contains("RoleBinding") or contains("updated")) | select(.namespace=="test-namespace-001")'

# Step 8: Functional test - verify actual permissions work
# Create test pod with deploy SA (now view permissions)
kubectl run test-pod-sa-perms -n test-namespace-001 \
  --image=bitnami/kubectl:latest \
  --serviceaccount=test-namespace-001-sa-deploy \
  --restart=Never \
  --command -- sleep 3600

kubectl wait --for=condition=Ready pod/test-pod-sa-perms -n test-namespace-001 --timeout=60s

# Try to create resource (should fail - only view permissions)
kubectl exec test-pod-sa-perms -n test-namespace-001 -- kubectl create configmap test-cm --from-literal=key=value 2>&1 | grep "Forbidden" && echo "PASS: View permissions enforced" || echo "FAIL: Should not have create permissions"

# Try to list resources (should succeed - view allows list)
kubectl exec test-pod-sa-perms -n test-namespace-001 -- kubectl get pods && echo "PASS: View permissions allow list" || echo "FAIL: Should have list permissions"

# Cleanup
kubectl delete pod test-pod-sa-perms -n test-namespace-001 --grace-period=0 --force
```

**Expected Result**:
- ✅ Permission upgrade (view -> admin) applied successfully
- ✅ Permission downgrade (admin -> view) applied successfully
- ✅ ServiceAccount not recreated (UID unchanged)
- ✅ RoleBinding updated in-place
- ✅ Changes logged in JSON format
- ✅ Actual permissions match configured permissions
- ✅ Multiple permission changes handled correctly
- ✅ No service disruption during updates

**Security Considerations**:
- Permission changes should be audited in logs
- Downgrade from admin to view should be immediate
- No temporary privilege escalation during updates

**Log Verification**:
```bash
# Expected log entries
{
  "level": "info",
  "message": "Updating RoleBinding permissions",
  "action": "update_rolebinding",
  "namespace": "test-namespace-001",
  "rolebinding": "...",
  "old_role": "view",
  "new_role": "admin",
  "serviceAccount": "test-namespace-001-sa-deploy"
}
```

---

### Test 42: RoleBindings with Hyphenated Roles (Bug Fix v1.5.2)

**Objective**: Verify operator correctly handles RoleBindings with hyphenated role names (e.g., "read-only", "cluster-admin")

**Background**:
Previous bug (fixed in v1.5.2): RoleBindings with roles containing hyphens were incorrectly deleted as obsolete because `extractRoleFromRoleBindingName()` only extracted the last segment after splitting by hyphens. For example, "production-read-only" would extract "only" instead of "read-only", causing the RoleBinding to be deleted when "only" wasn't found in the role mapping.

**Setup**:
```bash
# Create PermissionBinder with hyphenated role mappings
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-hyphenated-roles
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: edit
    "read-only": view  # Role with hyphen
    "cluster-admin": cluster-admin  # Role with hyphen
    admin: admin
EOF

# Create ConfigMap entries with hyphenated roles
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |-
    CN=COMPANY-K8S-test-ns-read-only,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-test-ns-cluster-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-test-ns-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
EOF

sleep 10
```

**Execution**:
```bash
# Step 1: Verify RoleBindings created for hyphenated roles
kubectl get rolebinding -n test-ns -o json | jq -r '.items[] | select(.metadata.annotations."permission-binder.io/managed-by" == "permission-binder-operator") | "\(.metadata.name) -> \(.roleRef.name)"'

# Verify "read-only" RoleBinding exists
kubectl get rolebinding test-ns-read-only -n test-ns && echo "PASS: read-only RoleBinding exists" || echo "FAIL: read-only RoleBinding missing"

# Verify "cluster-admin" RoleBinding exists
kubectl get rolebinding test-ns-cluster-admin -n test-ns && echo "PASS: cluster-admin RoleBinding exists" || echo "FAIL: cluster-admin RoleBinding missing"

# Step 2: Verify AnnotationRole annotation stores full role name
READ_ONLY_ROLE=$(kubectl get rolebinding test-ns-read-only -n test-ns -o jsonpath='{.metadata.annotations.permission-binder\.io/role}')
CLUSTER_ADMIN_ROLE=$(kubectl get rolebinding test-ns-cluster-admin -n test-ns -o jsonpath='{.metadata.annotations.permission-binder\.io/role}')

echo "AnnotationRole for read-only: $READ_ONLY_ROLE"
echo "AnnotationRole for cluster-admin: $CLUSTER_ADMIN_ROLE"

if [ "$READ_ONLY_ROLE" == "read-only" ]; then
  echo "PASS: AnnotationRole correctly stores 'read-only'"
else
  echo "FAIL: AnnotationRole should be 'read-only', got: $READ_ONLY_ROLE"
fi

if [ "$CLUSTER_ADMIN_ROLE" == "cluster-admin" ]; then
  echo "PASS: AnnotationRole correctly stores 'cluster-admin'"
else
  echo "FAIL: AnnotationRole should be 'cluster-admin', got: $CLUSTER_ADMIN_ROLE"
fi

# Step 3: Trigger reconciliation (this previously caused deletion bug)
kubectl annotate permissionbinder test-hyphenated-roles -n permissions-binder-operator trigger-reconcile="$(date +%s)" --overwrite

sleep 10

# Step 4: Verify RoleBindings NOT deleted (bug fix verification)
kubectl get rolebinding test-ns-read-only -n test-ns && echo "PASS: read-only RoleBinding NOT deleted after reconciliation" || echo "FAIL: read-only RoleBinding was deleted!"

kubectl get rolebinding test-ns-cluster-admin -n test-ns && echo "PASS: cluster-admin RoleBinding NOT deleted after reconciliation" || echo "FAIL: cluster-admin RoleBinding was deleted!"

# Step 5: Verify no "Deleted obsolete RoleBinding" logs for hyphenated roles
OBsolete_LOGS=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=100 | jq -r 'select(.message | contains("Deleted obsolete RoleBinding")) | select(.name | contains("read-only") or contains("cluster-admin"))')

if [ -z "$OBsolete_LOGS" ]; then
  echo "PASS: No incorrect deletion logs for hyphenated roles"
else
  echo "FAIL: Found incorrect deletion logs: $OBsolete_LOGS"
fi

# Step 6: Test role removal from mapping (should delete correctly)
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-hyphenated-roles
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: edit
    admin: admin
    # REMOVED: "read-only" and "cluster-admin"
EOF

sleep 10

# Verify hyphenated role RoleBindings ARE deleted when role removed from mapping
kubectl get rolebinding test-ns-read-only -n test-ns 2>&1 | grep "NotFound" && echo "PASS: read-only RoleBinding correctly deleted when role removed" || echo "FAIL: read-only RoleBinding should be deleted"

kubectl get rolebinding test-ns-cluster-admin -n test-ns 2>&1 | grep "NotFound" && echo "PASS: cluster-admin RoleBinding correctly deleted when role removed" || echo "FAIL: cluster-admin RoleBinding should be deleted"

# Verify engineer RoleBinding still exists (not removed)
kubectl get rolebinding test-ns-engineer -n test-ns && echo "PASS: engineer RoleBinding preserved (role still in mapping)" || echo "FAIL: engineer RoleBinding incorrectly deleted"
```

**Expected Result**:
- ✅ RoleBindings with hyphenated roles created successfully
- ✅ AnnotationRole annotation stores full role name (e.g., "read-only", not "only")
- ✅ RoleBindings NOT deleted incorrectly during reconciliation
- ✅ No "Deleted obsolete RoleBinding" logs for hyphenated roles when roles exist in mapping
- ✅ RoleBindings correctly deleted when role removed from mapping
- ✅ Other RoleBindings preserved when specific role removed
- ✅ Backward compatibility: Works with existing RoleBindings without AnnotationRole

**Related Bug**: Fixed in v1.5.2 - RoleBinding deletion check for hyphenated roles

---

### Test 43: Invalid Whitelist Entry Handling (Bug Fix v1.5.3)

**Objective**: Verify operator gracefully handles invalid whitelist entries without crashing or spamming error logs

**Background**:
Previous bug (fixed in v1.5.3): Invalid whitelist entries were logged as `logger.Error()` with stacktraces, causing noise in logs and potential operator instability. The fix changed error logging to `logger.Info()` with detailed context, allowing operator to skip invalid entries and continue processing.

**Setup**:
```bash
# Create PermissionBinder
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-invalid-entries
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: edit
    admin: admin
EOF

# Create ConfigMap with mix of valid and invalid entries
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |-
    # Valid entry
    CN=COMPANY-K8S-valid-ns-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Invalid entry: Missing prefix
    CN=INVALID-PREFIX-ns-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Invalid entry: Missing role
    CN=COMPANY-K8S-ns-unknownrole,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Invalid entry: Malformed LDAP DN
    INVALID-LDAP-DN-FORMAT
    
    # Invalid entry: Empty CN
    CN=,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Another valid entry (should be processed)
    CN=COMPANY-K8S-valid-ns-2-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
EOF

sleep 10
```

**Execution**:
```bash
# Step 1: Verify operator is still running (didn't crash)
kubectl get pod -n permissions-binder-operator -l control-plane=controller-manager -o jsonpath='{.items[0].status.phase}' | grep "Running" && echo "PASS: Operator running" || echo "FAIL: Operator crashed or not running"

# Step 2: Verify valid entries were processed
kubectl get namespace valid-ns && echo "PASS: Valid namespace created" || echo "FAIL: Valid namespace not created"
kubectl get namespace valid-ns-2 && echo "PASS: Second valid namespace created" || echo "FAIL: Second valid namespace not created"

kubectl get rolebinding valid-ns-engineer -n valid-ns && echo "PASS: Valid RoleBinding created" || echo "FAIL: Valid RoleBinding not created"
kubectl get rolebinding valid-ns-2-admin -n valid-ns-2 && echo "PASS: Second valid RoleBinding created" || echo "FAIL: Second valid RoleBinding not created"

# Step 3: Verify invalid entries logged as INFO (not ERROR)
ERROR_LOGS=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=200 | jq -r 'select(.level == "error") | select(.message | contains("parse") or contains("extract") or contains("invalid")) | .message')

if [ -z "$ERROR_LOGS" ]; then
  echo "PASS: No ERROR level logs for invalid entries"
else
  echo "FAIL: Found ERROR level logs: $ERROR_LOGS"
fi

# Step 4: Verify invalid entries logged as INFO with detailed context
INFO_LOGS=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=200 | jq -r 'select(.level == "info") | select(.message | contains("Skipping invalid") or contains("cannot parse") or contains("cannot extract"))')

if [ -n "$INFO_LOGS" ]; then
  echo "PASS: Invalid entries logged as INFO"
  echo "INFO logs found:"
  echo "$INFO_LOGS" | head -5
else
  echo "FAIL: No INFO level logs for invalid entries"
fi

# Step 5: Verify log entries contain required fields
LOG_ENTRY=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=200 | jq -r 'select(.message | contains("Skipping invalid")) | select(.line != null) | .' | head -1)

if [ -n "$LOG_ENTRY" ]; then
  echo "PASS: Log entry contains required fields"
  echo "Sample log entry:"
  echo "$LOG_ENTRY" | jq '{line, cn, reason, action}'
  
  # Verify specific fields
  HAS_LINE=$(echo "$LOG_ENTRY" | jq -r '.line != null')
  HAS_REASON=$(echo "$LOG_ENTRY" | jq -r '.reason != null')
  HAS_ACTION=$(echo "$LOG_ENTRY" | jq -r '.action == "skip"')
  
  if [ "$HAS_LINE" == "true" ] && [ "$HAS_REASON" == "true" ] && [ "$HAS_ACTION" == "true" ]; then
    echo "PASS: All required fields present (line, reason, action)"
  else
    echo "FAIL: Missing required fields"
  fi
else
  echo "FAIL: No log entries with required fields found"
fi

# Step 6: Verify no stacktraces in logs
STACKTRACE=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=200 | grep -i "stacktrace\|panic\|goroutine" || echo "")

if [ -z "$STACKTRACE" ]; then
  echo "PASS: No stacktraces in logs"
else
  echo "FAIL: Found stacktrace in logs"
  echo "$STACKTRACE"
fi

# Step 7: Test multiple invalid entries (stress test)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |-
    $(for i in {1..10}; do echo "INVALID-ENTRY-$i"; done)
    CN=COMPANY-K8S-stress-test-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
EOF

sleep 10

# Verify operator still running and valid entry processed
kubectl get pod -n permissions-binder-operator -l control-plane=controller-manager -o jsonpath='{.items[0].status.phase}' | grep "Running" && echo "PASS: Operator survived stress test" || echo "FAIL: Operator crashed during stress test"

kubectl get namespace stress-test && echo "PASS: Valid entry processed despite many invalid entries" || echo "FAIL: Valid entry not processed"

# Step 8: Verify same invalid entry doesn't cause repeated error attempts
INVALID_COUNT=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=500 | jq -r 'select(.message | contains("Skipping invalid")) | select(.cn == "INVALID-ENTRY-1") | .line' | wc -l)

echo "Invalid entry logged $INVALID_COUNT times"

# Each reconciliation should log it once, but not repeatedly in same reconciliation
if [ "$INVALID_COUNT" -le 5 ]; then
  echo "PASS: Invalid entry not logged excessively"
else
  echo "WARN: Invalid entry logged many times ($INVALID_COUNT), may indicate retry loop"
fi
```

**Expected Result**:
- ✅ Operator continues running (doesn't crash on invalid entries)
- ✅ Valid entries processed successfully despite invalid entries
- ✅ Invalid entries logged as INFO level (not ERROR)
- ✅ Log entries contain: line number, CN value, reason, action="skip"
- ✅ No stacktraces in logs
- ✅ Operator handles many invalid entries without performance degradation
- ✅ Same invalid entry logged once per reconciliation (not repeatedly)
- ✅ Valid entries processed even when mixed with invalid entries

**Log Format Verification**:
```bash
# Expected log format (JSON)
{
  "level": "info",
  "msg": "Skipping invalid permission string - cannot parse CN value",
  "line": 3,
  "cn": "COMPANY-K8S-ns-unknownrole",
  "reason": "no matching role found in roleMapping for: COMPANY-K8S-ns-unknownrole (available roles: [engineer admin])",
  "action": "skip"
}
```

**Related Bug**: Fixed in v1.5.3 - Improved error handling for invalid whitelist entries

---

