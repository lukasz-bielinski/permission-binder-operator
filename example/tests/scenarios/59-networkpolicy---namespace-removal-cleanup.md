### Test 59: NetworkPolicy - Namespace Removal Cleanup

**Objective**: Verify operator creates removal PRs and updates status when namespaces are removed from the whitelist.

**Setup**:
```bash
# Ensure GitHub credentials Secret exists (with write access)
# (If missing, create from temp/github-gitops-credentials-secret.yaml)

# Create PermissionBinder with two namespaces in whitelist
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-permissionbinder-networkpolicy-removal
  namespace: permissions-binder-operator
spec:
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: "edit"
    viewer: "view"
  configMapName: "permission-config-removal"
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
    backupExisting: true
    reconciliationInterval: "1h"
EOF

# Initial whitelist with two namespaces
data='CN=COMPANY-K8S-test-remove-a-engineer,OU=Openshift,DC=example,DC=com
CN=COMPANY-K8S-test-remove-b-engineer,OU=Openshift,DC=example,DC=com'
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config-removal
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
$(printf "%s" "$data")
EOF
```

**Execution**:
```bash
# Wait for initial reconciliation (PRs for both namespaces)
sleep 30

# Remove one namespace from whitelist (test-remove-b removed)
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config-removal
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-remove-a-engineer,OU=Openshift,DC=example,DC=com
EOF

# Wait for removal processing
sleep 30

# Inspect status entries for removal state
kubectl get permissionbinder test-permissionbinder-networkpolicy-removal -n permissions-binder-operator -o jsonpath='{.status.networkPolicies}'

# Fetch removal PR number/URL for removed namespace (state should be pr-removal)
kubectl get permissionbinder test-permissionbinder-networkpolicy-removal -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-remove-b")].prNumber}'
```

**Expected Result**:
- ✅ Remaining namespace (`test-remove-a`) stays in normal state (`pr-created`/`pr-merged`)
- ✅ Removed namespace (`test-remove-b`) transitions to `state: pr-removal`
- ✅ Removal PR number/URL recorded in status, `removedAt` timestamp populated
- ✅ Operator logs mention removal PR creation
- ✅ Git removal PR exists on GitHub (verified via `gh pr view`)

**Cleanup**:
```bash
kubectl delete permissionbinder test-permissionbinder-networkpolicy-removal -n permissions-binder-operator
kubectl delete configmap permission-config-removal -n permissions-binder-operator
```

---
