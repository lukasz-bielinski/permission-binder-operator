### Test 55: NetworkPolicy - Multiple PermissionBinders Validation

**Objective**: Verify operator warns when multiple PermissionBinder CRs have NetworkPolicy enabled

**Setup**:
```bash
# Create GitHub GitOps credentials Secret from dedicated file
# File location: temp/github-gitops-credentials-secret.yaml
kubectl apply -f temp/github-gitops-credentials-secret.yaml

# Create FIRST PermissionBinder with NetworkPolicy enabled
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-permissionbinder-networkpolicy-1
  namespace: permissions-binder-operator
spec:
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: "edit"
    viewer: "view"
  configMapName: "permission-config-1"
  configMapNamespace: "permissions-binder-operator"
  networkPolicy:
    enabled: true
    gitRepository:
      provider: "github"
      url: "https://github.com/lukasz-bielinski/tests-network-policies.git"
      baseBranch: "main"
      clusterName: "DEV-cluster"
      credentialsSecretRef:
        name: "github-gitops-credentials"
        namespace: "permissions-binder-operator"
    templateDir: "networkpolicies/templates"
    autoMerge:
      enabled: false
    excludeNamespaces:
      explicit:
        - "kube-system"
        - "kube-public"
      patterns:
        - "^kube-.*"
        - "^openshift-.*"
    backupExisting: true
    reconciliationInterval: "1h"
EOF

# Create SECOND PermissionBinder with NetworkPolicy enabled (should trigger warning)
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-permissionbinder-networkpolicy-2
  namespace: permissions-binder-operator
spec:
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: "edit"
    viewer: "view"
  configMapName: "permission-config-2"
  configMapNamespace: "permissions-binder-operator"
  networkPolicy:
    enabled: true
    gitRepository:
      provider: "github"
      url: "https://github.com/lukasz-bielinski/tests-network-policies.git"
      baseBranch: "main"
      clusterName: "DEV-cluster"
      credentialsSecretRef:
        name: "github-gitops-credentials"
        namespace: "permissions-binder-operator"
    templateDir: "networkpolicies/templates"
    autoMerge:
      enabled: false
    excludeNamespaces:
      explicit:
        - "kube-system"
        - "kube-public"
      patterns:
        - "^kube-.*"
        - "^openshift-.*"
    backupExisting: true
    reconciliationInterval: "1h"
EOF
```

**Execution**:
```bash
# Wait for reconciliation
sleep 10

# Check operator logs for warning about multiple CRs
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | grep -i "multiple.*permissionbinder.*networkpolicy\|multiple.*crs.*networkpolicy"

# Check metrics for warning
curl -s http://localhost:8080/metrics | grep 'permission_binder_multiple_crs_networkpolicy_warning_total'
```

**Expected Result**:
- ✅ Operator logs warning: "Multiple PermissionBinder CRs have NetworkPolicy enabled"
- ✅ Warning includes count of CRs with NetworkPolicy enabled
- ✅ `permission_binder_multiple_crs_networkpolicy_warning_total` metric incremented
- ✅ Warning logged with severity: "warning"
- ✅ Warning logged with security_impact: "medium"
- ✅ Warning includes recommendation: "Only one PermissionBinder CR should have NetworkPolicy enabled"
- ✅ Warning includes audit trail
- ✅ Operator continues to function (doesn't block operations)

**Note**: This validation:
- Prevents conflicts from multiple CRs managing NetworkPolicies
- Warns but doesn't block (allows graceful migration)
- Logs with appropriate severity for compliance
- Tracks via metrics for monitoring

---

