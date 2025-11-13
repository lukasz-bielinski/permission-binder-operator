### Test 44: NetworkPolicy - Variant A (New File from Template)

**Objective**: Verify operator creates Pull Request for new namespace from template

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

# Create ConfigMap with test namespaces
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-app-engineer,OU=Openshift,DC=example,DC=com
    CN=COMPANY-K8S-test-app-2-viewer,OU=Openshift,DC=example,DC=com
EOF
```

**Execution**:
```bash
# Wait for reconciliation
sleep 10

# Check PermissionBinder status for NetworkPolicy entries
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[*].namespace}'

# Verify test-app namespace has PR state
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-app")].state}'
```

**Expected Result**:
- ✅ NetworkPolicy status entries created for test-app and test-app-2 namespaces
- ✅ test-app namespace has PR state: "pr-created", "pr-pending", or "pr-merged"
- ✅ Pull Request created in GitHub repository with NetworkPolicy files
- ✅ PR number, URL, and branch stored in PermissionBinder status
- ✅ PR exists on GitHub (verified via `gh` CLI)
- ✅ PR contains expected files:
  - `networkpolicies/DEV-cluster/test-app/test-app-deny-all-ingress.yaml`
  - `networkpolicies/DEV-cluster/kustomization.yaml` (updated)
- ✅ PR title contains namespace name
- ✅ PR description contains cluster, namespace, and variant information
- ✅ kustomization.yaml contains correct relative paths (no `../../` prefixes)

---

