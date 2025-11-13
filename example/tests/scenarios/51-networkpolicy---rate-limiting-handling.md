### Test 51: NetworkPolicy - Rate Limiting Handling

**Objective**: Verify operator handles GitHub API rate limiting gracefully

**Setup**:
```bash
# Create GitHub GitOps credentials Secret from dedicated file
# File location: temp/github-gitops-credentials-secret.yaml
kubectl apply -f temp/github-gitops-credentials-secret.yaml

# Create PermissionBinder with NetworkPolicy enabled
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
# Simulate rate limit by creating many namespaces rapidly
# Or use GitHub API to check current rate limit status
# Or inject rate limit error in operator logs

# Create multiple namespaces to trigger rate limit
for i in {1..10}; do
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-ratelimit-$i-engineer,OU=Openshift,DC=example,DC=com
EOF
  sleep 1
done

# Check operator logs for rate limit errors
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | grep -i "rate limit"

# Check metrics for rate limit errors
curl -s http://localhost:8080/metrics | grep 'permission_binder_networkpolicy_pr_creation_errors_total.*rate_limit'
```

**Expected Result**:
- ✅ Operator logs rate limit errors with appropriate severity
- ✅ `permission_binder_networkpolicy_pr_creation_errors_total{error_type="rate_limit"}` incremented
- ✅ Operator does not crash on rate limit errors
- ✅ Operator continues processing other namespaces
- ✅ Error message includes context (namespace, action)
- ✅ Rate limit errors are logged with audit trail

**Note**: This test may require:
- Simulating rate limit (difficult in real environment)
- Or checking operator behavior when rate limit occurs naturally
- Or using GitHub API to check rate limit status before test
- Verification that operator handles rate limit gracefully without crashing

---

