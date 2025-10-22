# Permission Binder Operator - Operational Runbook

**Version:** 1.0  
**Last Updated:** 2025-10-15  
**Maintainer:** Platform Team  
**Severity Levels:** P1 (Critical), P2 (High), P3 (Medium), P4 (Low)

---

## Quick Reference

### Critical Commands
```bash
# Check operator status
kubectl get pods -n permissions-binder-operator

# View JSON logs
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | jq '.'

# Check managed resources
kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator

# Access metrics
kubectl port-forward -n permissions-binder-operator deployment/operator-controller-manager 8443:8443
curl -k https://localhost:8443/metrics | grep permission_binder
```

---

## Incident Response

### P1 - Operator Down (15 min SLA)

**Symptoms:**
- Alert: `PermissionBinderOperatorDown`
- No logs in last 10 minutes
- Pod in CrashLoopBackOff or not running

**Diagnosis:**
```bash
# 1. Check pod status
kubectl get pods -n permissions-binder-operator

# 2. Check pod description
kubectl describe pod -n permissions-binder-operator -l control-plane=controller-manager

# 3. Check logs (current)
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | jq '.'

# 4. Check previous logs (if restarted)
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --previous | jq '.'

# 5. Check events
kubectl get events -n permissions-binder-operator --sort-by='.lastTimestamp'
```

**Resolution:**
1. **Image pull failure**: Check image exists in registry
   ```bash
   docker pull lukaszbielinski/permission-binder-operator:latest
   ```

2. **OOMKilled**: Increase memory limits
   ```bash
   kubectl patch deployment operator-controller-manager -n permissions-binder-operator \
     --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "512Mi"}]'
   ```

3. **CrashLoopBackOff**: Check logs for panic/error
   ```bash
   kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --previous | jq 'select(.level=="error")'
   ```

4. **Restart operator**:
   ```bash
   kubectl rollout restart deployment operator-controller-manager -n permissions-binder-operator
   ```

**Escalation:** If restart doesn't help after 3 attempts → Senior Platform Engineer

---

### P1 - Missing ClusterRole (Security Critical)

**Symptoms:**
- Alert: `PermissionBinderMissingClusterRole`
- Users report "permission denied"
- JSON logs show `severity: warning`, `security_impact: high`

**Diagnosis:**
```bash
# 1. Identify missing ClusterRoles
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq -r 'select(.severity=="warning" and .clusterRole) | .clusterRole' | sort -u

# 2. Check if ClusterRole exists
kubectl get clusterrole <clusterrole-name>

# 3. Check affected namespaces
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq -r 'select(.clusterRole=="<clusterrole-name>") | .namespace' | sort -u
```

**Resolution:**
1. **Create missing ClusterRole** (if supposed to exist):
   ```bash
   # Example for edit role
   kubectl create clusterrole clusterrole-engineer \
     --verb=get,list,watch,create,update,patch,delete \
     --resource=pods,services,deployments,configmaps
   ```

2. **Or remove from mapping** (if not needed):
   ```bash
   kubectl patch permissionbinder permissionbinder-example -n permissions-binder-operator \
     --type=json -p='[{"op":"remove","path":"/spec/roleMapping/<role>"}]'
   ```

3. **Verify RoleBindings start working**:
   ```bash
   kubectl auth can-i get pods --as=system:group:<group-name> -n <namespace>
   ```

**Escalation:** Security team must approve new ClusterRoles

---

### P2 - Orphaned Resources Detected

**Symptoms:**
- Alert: `PermissionBinderOrphanedResourcesDetected`
- Resources have `orphaned-at` annotation
- PermissionBinder was deleted

**Diagnosis:**
```bash
# 1. List orphaned RoleBindings
kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator \
  -o json | jq '.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"]) | {namespace: .metadata.namespace, name: .metadata.name, orphanedAt: .metadata.annotations["permission-binder.io/orphaned-at"]}'

# 2. List orphaned Namespaces
kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator \
  -o json | jq '.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"]) | {name: .metadata.name, orphanedAt: .metadata.annotations["permission-binder.io/orphaned-at"]}'

# 3. Check if PermissionBinder exists
kubectl get permissionbinders -A
```

**Resolution:**

**Option A: Adopt resources (RECOMMENDED)**
```bash
# 1. Recreate PermissionBinder with same name/namespace
kubectl apply -f permissionbinder-example.yaml

# 2. Wait for adoption (30 seconds)
sleep 30

# 3. Verify adoption in logs
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq 'select(.action=="adoption")'

# 4. Verify orphaned annotations removed
kubectl get rolebindings -A -o json \
  | jq '.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])'
# Should return empty
```

**Option B: Manual cleanup** (if intentional)
```bash
# 1. Delete orphaned RoleBindings
kubectl delete rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator

# 2. Remove annotations from Namespaces (DON'T delete namespaces!)
for ns in $(kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator -o name); do
  kubectl annotate $ns permission-binder.io/orphaned-at- permission-binder.io/orphaned-by-
  kubectl label $ns permission-binder.io/managed-by-
done
```

---

### P2 - High Error Rate

**Symptoms:**
- Alert: `PermissionBinderHighErrorRate`
- Error rate > 0.5/second for 5+ minutes

**Diagnosis:**
```bash
# 1. Check error logs
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq 'select(.level=="error") | {timestamp, message, error}'

# 2. Group errors by type
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq -r 'select(.level=="error") | .message' | sort | uniq -c | sort -rn

# 3. Check for permission errors
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq 'select(.error | contains("forbidden"))'
```

**Common Issues:**

1. **Permission Denied**:
   ```bash
   # Check operator RBAC
   kubectl get clusterrolebinding operator-manager-rolebinding -o yaml
   
   # Verify it uses cluster-admin
   # If not, fix:
   kubectl patch clusterrolebinding operator-manager-rolebinding \
     --type='json' -p='[{"op":"replace","path":"/roleRef/name","value":"cluster-admin"}]'
   ```

2. **Invalid ConfigMap entries**:
   ```bash
   # Find problematic entries
   kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
     | jq 'select(.message | contains("Failed to parse")) | .key'
   
   # Remove from ConfigMap
   kubectl patch configmap permission-config -n permissions-binder-operator \
     --type=json -p='[{"op":"remove","path":"/data/<key>"}]'
   ```

---

### P3 - Slow Reconciliation

**Symptoms:**
- Alert: `PermissionBinderSlowReconciliation`
- P99 > 30 seconds

**Diagnosis:**
```bash
# Check ConfigMap size
kubectl get configmap permission-config -n permissions-binder-operator -o json | jq '.data | length'

# Check number of managed resources
kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator | wc -l

# Check operator resource usage
kubectl top pod -n permissions-binder-operator
```

**Resolution:**
1. **Large ConfigMap**: Split into multiple PermissionBinders
2. **Resource limits**: Increase CPU/memory
3. **Too many namespaces**: Review architecture

---

## Troubleshooting Playbooks

### Playbook 1: Users Can't Access Namespace

**Steps:**
1. Verify RoleBinding exists:
   ```bash
   kubectl get rolebindings -n <namespace> -l permission-binder.io/managed-by=permission-binder-operator
   ```

2. Check RoleBinding subjects:
   ```bash
   kubectl get rolebinding <name> -n <namespace> -o yaml | grep -A 5 subjects
   ```

3. Verify user's groups:
   ```bash
   kubectl auth can-i get pods --as=system:group:<group-name> -n <namespace>
   ```

4. Check ClusterRole exists:
   ```bash
   kubectl get clusterrole <clusterrole-name>
   ```

5. Check operator logs for warnings:
   ```bash
   kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
     | jq 'select(.namespace=="<namespace>" and .severity=="warning")'
   ```

---

### Playbook 2: Operator Won't Start

**Common causes:**

1. **Invalid image**:
   ```bash
   kubectl describe pod -n permissions-binder-operator -l control-plane=controller-manager | grep -A 5 Events
   ```

2. **RBAC issues**:
   ```bash
   kubectl get serviceaccount operator-controller-manager -n permissions-binder-operator
   kubectl get clusterrolebinding operator-manager-rolebinding
   ```

3. **Resource limits**:
   ```bash
   kubectl get deployment operator-controller-manager -n permissions-binder-operator -o yaml | grep -A 10 resources
   ```

---

### Playbook 3: Manual Cleanup of Orphaned Resources

**When:** PermissionBinder permanently deleted, resources need cleanup

**Steps:**
1. **Backup first!**
   ```bash
   kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o yaml > backup-orphaned-rb.yaml
   kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator -o yaml > backup-orphaned-ns.yaml
   ```

2. **List orphaned resources**:
   ```bash
   # RoleBindings
   kubectl get rolebindings -A -o json | jq '.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"]) | {namespace: .metadata.namespace, name: .metadata.name}'
   
   # Namespaces
   kubectl get namespaces -o json | jq '.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"]) | .metadata.name'
   ```

3. **Delete orphaned RoleBindings**:
   ```bash
   kubectl delete rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator
   ```

4. **Clean namespace annotations** (DON'T delete namespaces!):
   ```bash
   for ns in $(kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator -o jsonpath='{.items[*].metadata.name}'); do
     kubectl annotate namespace $ns \
       permission-binder.io/managed-by- \
       permission-binder.io/created-at- \
       permission-binder.io/permission-binder- \
       permission-binder.io/orphaned-at- \
       permission-binder.io/orphaned-by-
     kubectl label namespace $ns permission-binder.io/managed-by-
   done
   ```

---

## Maintenance Procedures

### Updating Operator

**Pre-flight checks:**
```bash
# 1. Backup current CRs
kubectl get permissionbinders -A -o yaml > backup-pbs-$(date +%Y%m%d).yaml

# 2. Check current version
kubectl get deployment operator-controller-manager -n permissions-binder-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# 3. Test in non-prod first!
```

**Update procedure:**
```bash
# 1. Update image in deployment
kubectl set image deployment/operator-controller-manager \
  manager=lukaszbielinski/permission-binder-operator:<new-version> \
  -n permissions-binder-operator

# 2. Watch rollout
kubectl rollout status deployment/operator-controller-manager -n permissions-binder-operator

# 3. Verify logs
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=50 | jq '.'

# 4. Check metrics
curl -k https://localhost:8443/metrics | grep permission_binder

# 5. Verify reconciliation
kubectl annotate permissionbinder permissionbinder-example -n permissions-binder-operator \
  test-trigger="$(date +%s)" --overwrite
```

**Rollback:**
```bash
kubectl rollout undo deployment/operator-controller-manager -n permissions-binder-operator
kubectl rollout status deployment/operator-controller-manager -n permissions-binder-operator
```

---

### Updating PermissionBinder Configuration

**Safe procedure:**
```bash
# 1. Backup current config
kubectl get permissionbinder permissionbinder-example -n permissions-binder-operator -o yaml > backup-pb.yaml

# 2. Make changes in git first

# 3. Apply changes
kubectl apply -f permissionbinder-example.yaml

# 4. Monitor logs for warnings
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager -f \
  | jq 'select(.severity=="warning" or .level=="error")'

# 5. Verify expected resources created/updated
kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator
```

**Rollback:**
```bash
kubectl apply -f backup-pb.yaml
```

---

## Monitoring & Alerting

### Key Metrics

**Operator Health:**
```promql
# Operator up
up{job="operator-controller-manager-metrics-service",namespace="permissions-binder-operator"}

# Reconciliation rate
rate(controller_runtime_reconcile_total{controller="permissionbinder"}[5m])

# Error rate
rate(controller_runtime_reconcile_errors_total{controller="permissionbinder"}[5m])

# Success rate (SLO: 99.9%)
1 - (rate(controller_runtime_reconcile_errors_total[5m]) / rate(controller_runtime_reconcile_total[5m]))
```

**Custom Metrics:**
```promql
# Missing ClusterRoles (security critical!)
permission_binder_missing_clusterrole_total

# Orphaned resources
permission_binder_orphaned_resources_total

# Adoptions (recovery success)
permission_binder_adoption_events_total

# Managed resources
permission_binder_managed_rolebindings_total
permission_binder_managed_namespaces_total

# ConfigMap processing
permission_binder_configmap_entries_processed_total
```

**Log Queries (Loki/Grafana):**
```logql
# All errors
{namespace="permissions-binder-operator"} | json | level="error"

# Security warnings
{namespace="permissions-binder-operator"} | json | severity="warning"

# Missing ClusterRoles
{namespace="permissions-binder-operator"} | json | clusterRole!=""

# Orphaned resources
{namespace="permissions-binder-operator"} | json | message=~".*orphaned.*"

# Adoption events
{namespace="permissions-binder-operator"} | json | action="adoption"
```

---

## Regular Maintenance

### Daily
- ✅ Check for alerts in AlertManager
- ✅ Review error logs (should be < 5 errors/day)
- ✅ Verify operator is running

### Weekly
- ✅ Check for orphaned resources (should be 0)
- ✅ Review security warnings (missing ClusterRoles)
- ✅ Verify metrics endpoint accessible
- ✅ Check resource usage trends

### Monthly
- ✅ Review and update PermissionBinder configurations
- ✅ Audit managed resources vs ConfigMap
- ✅ Performance review (reconciliation times)
- ✅ Update documentation if needed

### Quarterly
- ✅ Disaster recovery drill
- ✅ Update operator version
- ✅ Security audit
- ✅ Review and optimize ClusterRoles

---

## Emergency Procedures

### Emergency: Revoke All Permissions Immediately

**Scenario:** Security incident, need to revoke all permissions

```bash
# Option 1: Delete all RoleBindings (FAST, 30 seconds)
kubectl delete rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator

# Option 2: Delete PermissionBinder (resources preserved but marked orphaned)
kubectl delete permissionbinder permissionbinder-example -n permissions-binder-operator
```

**Recovery:**
```bash
# Recreate PermissionBinder (resources will be adopted)
kubectl apply -f permissionbinder-example.yaml
```

---

### Emergency: Operator Causing Problems

**Scenario:** Operator is malfunctioning, creating wrong permissions

```bash
# 1. Scale down operator immediately
kubectl scale deployment operator-controller-manager -n permissions-binder-operator --replicas=0

# 2. Investigate logs
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  --tail=200 | jq '.' > operator-logs-$(date +%Y%m%d-%H%M%S).json

# 3. Review recent changes
kubectl get permissionbinder permissionbinder-example -n permissions-binder-operator -o yaml

# 4. Fix issue (update CR, fix operator, etc.)

# 5. Scale back up
kubectl scale deployment operator-controller-manager -n permissions-binder-operator --replicas=1
```

---

## Health Checks

### Operator Health
```bash
# Pod running?
kubectl get pods -n permissions-binder-operator -l control-plane=controller-manager

# Recent logs (no errors?)
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=20 \
  | jq 'select(.level=="error")'

# Metrics accessible?
kubectl port-forward -n permissions-binder-operator deployment/operator-controller-manager 8443:8443 &
curl -k https://localhost:8443/metrics | grep permission_binder
kill %1
```

### Data Integrity
```bash
# Count managed resources
echo "RoleBindings: $(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)"
echo "Namespaces: $(kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)"

# Check for orphaned
echo "Orphaned RoleBindings: $(kubectl get rolebindings -A -o json | jq '[.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])] | length')"
echo "Orphaned Namespaces: $(kubectl get namespaces -o json | jq '[.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])] | length')"

# Verify PermissionBinder status
kubectl get permissionbinder permissionbinder-example -n permissions-binder-operator -o yaml | grep -A 10 status
```

---

## Contacts & Escalation

### On-Call Rotation
- **Primary:** Platform Team (Slack: #platform-oncall)
- **Secondary:** Senior Platform Engineer
- **Escalation:** Security Team (for ClusterRole issues)

### SLA
- **P1 (Critical):** 15 minutes response, 1 hour resolution
- **P2 (High):** 1 hour response, 4 hours resolution
- **P3 (Medium):** Next business day
- **P4 (Low):** Best effort

### Communication
- Incidents: #incidents Slack channel
- Status updates: Every 30 minutes during P1
- Post-mortem: Within 48 hours of P1/P2

---

## References

- [E2E Test Scenarios](../example/e2e-test-scenarios.md)
- [Monitoring Guide](../example/monitoring/README.md)
- [Backup & Recovery](./BACKUP.md)

