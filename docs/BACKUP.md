# Backup & Restore - Permission Binder Operator

**Target Environment:** Production  
**RTO:** 15 minutes  
**RPO:** 5 minutes  
**Backup Solution:** Kasten K10 + Manual exports

---

## Overview

Permission Binder Operator uses a **declarative approach** with **automatic recovery**:
- PermissionBinder CRs define desired state
- Operator recreates RoleBindings automatically
- **Orphaned resource adoption** ensures zero data loss

---

## Backup Strategy

### 1. Kasten K10 Backup (RECOMMENDED)

#### Setup Kasten K10 Policy

```yaml
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: permission-binder-backup
  namespace: kasten-io
spec:
  frequency: "@hourly"
  retention:
    hourly: 24
    daily: 7
    weekly: 4
    monthly: 12
  selector:
    matchExpressions:
      - key: app.kubernetes.io/name
        operator: In
        values:
          - permission-binder-operator
  actions:
    - action: backup
      backupParameters:
        filters:
          includeResources:
            - group: permission.permission-binder.io
              version: v1
              resource: permissionbinders
            - group: ""
              version: v1
              resource: configmaps
              name: permission-config
          excludeResources:
            - group: rbac.authorization.k8s.io
              resource: rolebindings  # Don't backup - will be recreated
            - group: ""
              resource: namespaces     # Don't backup - already exist
```

#### Kasten K10 Restore

```bash
# 1. In Kasten K10 UI, find backup
# 2. Select "Restore"
# 3. Choose restore point (before incident)
# 4. Restore only PermissionBinder CRs and ConfigMaps
# 5. Verify operator adopts existing resources

# OR via K10 CLI:
kubectl create -f - <<EOF
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RestoreAction
metadata:
  name: restore-permission-binder-$(date +%Y%m%d-%H%M%S)
  namespace: kasten-io
spec:
  subject:
    name: permission-binder-backup
    kind: Policy
    namespace: kasten-io
  restorePoint: <restore-point-id>
EOF
```

---

### 2. Manual Git Backup (RECOMMENDED for GitOps)

**Setup automated export:**

```bash
#!/bin/bash
# File: /usr/local/bin/backup-permission-binder.sh

export KUBECONFIG=/path/to/kubeconfig
BACKUP_DIR=/backup/permission-binder
DATE=$(date +%Y%m%d-%H%M%S)

# Create backup directory
mkdir -p $BACKUP_DIR/$DATE

# Export PermissionBinder CRs
kubectl get permissionbinders -A -o yaml > $BACKUP_DIR/$DATE/permissionbinders.yaml

# Export ConfigMaps
kubectl get configmap permission-config -n permissions-binder-operator -o yaml \
  > $BACKUP_DIR/$DATE/configmap.yaml

# Commit to git
cd $BACKUP_DIR
git add .
git commit -m "Backup $(date)"
git push

# Cleanup old backups (keep 30 days)
find $BACKUP_DIR -type d -mtime +30 -exec rm -rf {} +
```

**Cron schedule:**
```cron
# Every 4 hours
0 */4 * * * /usr/local/bin/backup-permission-binder.sh
```

---

### 3. On-Demand Backup

**Before major changes:**
```bash
# Backup everything
kubectl get permissionbinders -A -o yaml > backup-pb-$(date +%Y%m%d).yaml
kubectl get configmap permission-config -n permissions-binder-operator -o yaml > backup-cm-$(date +%Y%m%d).yaml

# Optionally backup current state of managed resources (for audit)
kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o yaml \
  > backup-rb-$(date +%Y%m%d).yaml
kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator -o yaml \
  > backup-ns-$(date +%Y%m%d).yaml
```

---

## Restore Procedures

### Scenario 1: Operator Deleted, Resources Orphaned

**Impact:** Resources exist but marked as orphaned  
**RTO:** 5 minutes  
**Data Loss:** None (SAFE MODE)

**Steps:**
```bash
# 1. Verify resources are orphaned
kubectl get rolebindings -A -o json \
  | jq '.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])'

# 2. Restore PermissionBinder CR
kubectl apply -f backup-pb-YYYYMMDD.yaml
# OR from git:
kubectl apply -f example/permissionbinder/permissionbinder-example.yaml

# 3. Wait for operator to adopt (30 seconds)
sleep 30

# 4. Verify adoption in logs
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq 'select(.action=="adoption")'

# 5. Verify orphaned annotations removed
kubectl get rolebindings -A -o json \
  | jq '.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])'
# Should return empty

# 6. Verify metrics
curl -k https://localhost:8443/metrics | grep permission_binder_orphaned_resources_total
# Should be 0
```

**Verification:** All orphaned resources adopted, no data loss

---

### Scenario 2: ConfigMap Corrupted

**Impact:** Operator processes invalid data  
**RTO:** 10 minutes  
**Data Loss:** None (operator logs errors but continues)

**Steps:**
```bash
# 1. Check error logs
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq 'select(.level=="error" and .message | contains("parse"))'

# 2. Restore ConfigMap from backup
kubectl apply -f backup-cm-YYYYMMDD.yaml

# 3. Verify operator processes correctly
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager -f \
  | jq 'select(.message | contains("Successfully processed"))'

# 4. Verify metrics
kubectl get permissionbinder permissionbinder-example -n permissions-binder-operator \
  -o jsonpath='{.status.processedRoleBindings}' | jq '.'
```

---

### Scenario 3: Complete Cluster Disaster

**Impact:** Total cluster loss  
**RTO:** 2 hours  
**Data Loss:** Max 4 hours (depends on backup frequency)

**Steps:**
```bash
# 1. Restore cluster from infrastructure backup

# 2. Reinstall operator
kubectl apply -k example/

# 3. Restore PermissionBinder CRs from git/backup
kubectl apply -f backup-pb-YYYYMMDD.yaml

# 4. Operator will recreate all RoleBindings automatically

# 5. Verify
kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | jq '.'
```

**Note:** Namespaces may already exist from other workloads - operator will adopt them

---

## Kasten K10 Integration

### Installation

```bash
# 1. Install Kasten K10
helm repo add kasten https://charts.kasten.io/
helm install k10 kasten/k10 --namespace=kasten-io --create-namespace

# 2. Configure location profile (e.g., S3, Azure Blob)
kubectl create -f - <<EOF
apiVersion: config.kio.kasten.io/v1alpha1
kind: Profile
metadata:
  name: s3-backup
  namespace: kasten-io
spec:
  type: Location
  locationSpec:
    type: ObjectStore
    objectStore:
      name: permission-binder-backups
      objectStoreType: S3
      region: eu-central-1
      bucket: your-backup-bucket
    credential:
      secretType: AwsAccessKey
      secret:
        apiVersion: v1
        kind: Secret
        name: k10-s3-secret
        namespace: kasten-io
EOF
```

### Backup Configuration

Apply the policy from Section 1 (Kasten K10 Policy above)

### Restore from Kasten

**UI Method:**
1. Open Kasten K10 dashboard
2. Navigate to "Applications" → "permissions-binder-operator"
3. Select restore point
4. Click "Restore"
5. Choose "Original namespace" or "New namespace"
6. Confirm restore

**CLI Method:**
```bash
# List restore points
kubectl get restorepoints -n kasten-io

# Create restore action
kubectl create -f restore-action.yaml
```

---

## Testing Backup & Restore

### Monthly DR Drill

**Test procedure:**
```bash
# 1. Backup current state
kubectl get permissionbinders -A -o yaml > pre-drill-pb.yaml

# 2. Simulate disaster - delete PermissionBinder
kubectl delete permissionbinder permissionbinder-example -n permissions-binder-operator

# 3. Wait 5 minutes (verify resources orphaned)
kubectl get rolebindings -A -o json | jq '.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])'

# 4. Restore from backup
kubectl apply -f pre-drill-pb.yaml

# 5. Verify adoption
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq 'select(.action=="adoption")' | wc -l

# 6. Verify metrics
curl -k https://localhost:8443/metrics | grep permission_binder_orphaned_resources_total
# Should show 0

# 7. Document results
echo "DR Drill $(date): SUCCESS" >> dr-drill-log.txt
```

---

## Backup Best Practices

### DO
- ✅ Backup PermissionBinder CRs every 4 hours
- ✅ Backup ConfigMaps every 4 hours
- ✅ Store backups in git (GitOps)
- ✅ Use Kasten K10 for automated backups
- ✅ Test restore monthly
- ✅ Keep backups for 90 days (compliance)

### DON'T
- ❌ Backup RoleBindings (recreated automatically)
- ❌ Backup Namespaces (may contain other workloads)
- ❌ Backup operator deployment (use GitOps)
- ❌ Rely on single backup solution

---

## Recovery Time Objectives

| Scenario | RTO | RPO | Method |
|----------|-----|-----|--------|
| Operator deleted | 5 min | 0 | Reapply from git |
| PermissionBinder deleted | 5 min | 0 | Restore + adoption |
| ConfigMap corrupted | 10 min | 4h | Restore from backup |
| Complete cluster loss | 2h | 4h | Infrastructure restore + CR restore |
| Namespace accidentally deleted | N/A | N/A | **PREVENTED** - operator never deletes namespaces |

---

## Compliance & Audit

### Backup Audit Trail
- Kasten K10 maintains backup history
- Git commits provide change tracking
- Operator logs record all operations

### Retention
- **Backups:** 90 days minimum
- **Logs:** 90 days (forwarded to SIEM)
- **Metrics:** 30 days (Prometheus)

### Access Control
- Backup access: Kubernetes cluster administrators
- Restore operations: Require proper RBAC permissions
- Audit logs: Monitor and review regularly

---

## Disaster Recovery Checklist

- [ ] Kasten K10 policy configured
- [ ] S3/Azure backup location configured
- [ ] Automated git backups enabled
- [ ] Monthly DR drill scheduled
- [ ] Runbook tested and validated
- [ ] Team trained on restore procedures
- [ ] Escalation contacts updated
- [ ] RTO/RPO documented and approved
- [ ] Compliance requirements met
- [ ] Backup monitoring alerts configured

---

## Support

**Issues:** [GitHub Issues](https://github.com/lukasz-bielinski/permission-binder-operator/issues)  
**Discussions:** [GitHub Discussions](https://github.com/lukasz-bielinski/permission-binder-operator/discussions)  
**Documentation:** [Repository Docs](https://github.com/lukasz-bielinski/permission-binder-operator)

---

## Version History

- **v1.0** (2025-10-15): Initial version with Kasten K10 integration

