### Test 53: NetworkPolicy - Git Operations Failures

**Objective**: Verify operator handles Git operation failures gracefully

**Setup**:
```bash
# Create GitHub GitOps credentials Secret with INVALID credentials
# This will cause Git operations to fail
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-gitops-credentials-invalid
  namespace: permissions-binder-operator
type: Opaque
stringData:
  token: "invalid-token-that-will-fail"
  username: "invalid-user"
  email: "invalid@example.com"
EOF

# Create PermissionBinder with NetworkPolicy enabled using invalid credentials
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-permissionbinder-networkpolicy
  namespace: permissions-binder-operator
spec:
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: "edit"
    viewer: "view"
  configMapName: "permission-config"
  configMapNamespace: "permissions-binder-operator"
  networkPolicy:
    enabled: true
    gitRepository:
      provider: "github"
      url: "https://github.com/lukasz-bielinski/tests-network-policies.git"
      baseBranch: "main"
      clusterName: "DEV-cluster"
      credentialsSecretRef:
        name: "github-gitops-credentials-invalid"
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

# Create ConfigMap with test namespace
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-git-failure-engineer,OU=Openshift,DC=example,DC=com
EOF
```

**Execution**:
```bash
# Wait for reconciliation
sleep 15

# Check operator logs for Git operation errors
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | grep -i "git\|clone\|push\|failed"

# Check PermissionBinder status for error state
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-git-failure")].state}'
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-git-failure")].errorMessage}'

# Check metrics for Git operation errors
curl -s http://localhost:8080/metrics | grep 'permission_binder_networkpolicy_git_operations_total.*error'
```

**Expected Result**:
- ✅ Operator logs Git operation errors with appropriate severity
- ✅ PermissionBinder status shows error state or error message
- ✅ Operator does not crash on Git operation failures
- ✅ Error messages include context (operation type, namespace)
- ✅ Git operation errors are logged with audit trail
- ✅ Metrics track Git operation failures (if implemented)
- ✅ Operator continues processing other namespaces (if applicable)
- ✅ RBAC reconciliation continues to work (graceful degradation)

**Note**: This test verifies:
- Git clone failures (invalid credentials, network issues)
- Git push failures (permission denied, network issues)
- Git checkout failures
- Error handling and logging
- Operator resilience (doesn't crash)

---

