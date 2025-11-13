### Test 49: NetworkPolicy - Auto-Merge PR

**Objective**: Verify operator automatically merges Pull Requests when auto-merge is enabled

**Setup**:
```bash
# Create GitHub GitOps credentials Secret from dedicated file
# File location: temp/github-gitops-credentials-secret.yaml
kubectl apply -f temp/github-gitops-credentials-secret.yaml

# Create PermissionBinder with NetworkPolicy enabled and auto-merge enabled
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
      enabled: true
      label: "auto-merge"
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
    CN=COMPANY-K8S-test-automerge-engineer,OU=Openshift,DC=example,DC=com
EOF
```

**Execution**:
```bash
# Wait for reconciliation
sleep 10

# Wait for PR to be created and auto-merged (up to 180s)
# Check PR state in PermissionBinder status
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-automerge")].state}'

# Verify PR on GitHub
gh pr view <PR_NUMBER> --repo lukasz-bielinski/tests-network-policies --json state,labels
```

**Expected Result**:
- ✅ PR created for test-automerge namespace
- ✅ PR has auto-merge label applied
- ✅ PR automatically merged (state: "MERGED" on GitHub)
- ✅ PermissionBinder status shows state: "pr-merged"
- ✅ PR number, URL, and branch stored in PermissionBinder status
- ✅ PR exists on GitHub and is merged
- ✅ NetworkPolicy files exist in main branch after merge

**Note**: Auto-merge requires:
- PR to be created successfully
- PR to pass any required checks (if configured in GitHub)
- Auto-merge label to be applied
- Operator to have merge permissions

---

