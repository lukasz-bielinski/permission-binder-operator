### Test 57: NetworkPolicy - Read-Only Repository Access (Forbidden)

**Objective**: Verify operator handles Git repository write permission errors (HTTP 403/permission denied) without crashing and with clear audit trail.

**Setup**:
```bash
# Create read-only GitHub credentials Secret (token without push scope)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-gitops-credentials-readonly
  namespace: permissions-binder-operator
type: Opaque
stringData:
  token: "READ_ONLY_TOKEN_PLACEHOLDER"
  username: "readonly-user"
  email: "readonly@example.com"
EOF

# Create PermissionBinder referencing the read-only secret
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-permissionbinder-networkpolicy-readonly
  namespace: permissions-binder-operator
spec:
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: "edit"
  configMapName: "permission-config-readonly"
  configMapNamespace: "permissions-binder-operator"
  networkPolicy:
    enabled: true
    gitRepository:
      provider: "github"
      url: "https://github.com/lukasz-bielinski/tests-network-policies.git"
      baseBranch: "main"
      clusterName: "DEV-cluster"
      credentialsSecretRef:
        name: "github-gitops-credentials-readonly"
        namespace: "permissions-binder-operator"
    templateDir: "networkpolicies/templates"
    autoMerge:
      enabled: false
    backupExisting: true
    reconciliationInterval: "1h"
EOF

# Create ConfigMap with test namespace
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config-readonly
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-readonly-engineer,OU=Openshift,DC=example,DC=com
EOF
```

**Execution**:
```bash
# Wait for reconciliation (operator attempts to push but receives 403/permission denied)
sleep 20

# Inspect PermissionBinder status for error message
kubectl get permissionbinder test-permissionbinder-networkpolicy-readonly -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[*].errorMessage}'

# Check operator logs for explicit forbidden/permission error
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | grep -i "permission\|forbidden\|403"

# Inspect metrics for failed Git operations (push errors)
curl -s http://localhost:8080/metrics | grep 'permission_binder_networkpolicy_git_operations_total.*status="error"'
```

**Expected Result**:
- ✅ Operator logs contain forbidden/permission denied details (HTTP 403)
- ✅ PermissionBinder status entry includes error message describing the failure
- ✅ NetworkPolicy status state does not transition to `pr-created` (no PR created)
- ✅ Git operation error metric increments (`status="error"`)
- ✅ Operator remains available (no crash / deployment stays Ready)
- ✅ Event recorded in audit logs with severity `error`

**Cleanup**:
```bash
kubectl delete permissionbinder test-permissionbinder-networkpolicy-readonly -n permissions-binder-operator
kubectl delete configmap permission-config-readonly -n permissions-binder-operator
kubectl delete secret github-gitops-credentials-readonly -n permissions-binder-operator
```

---
