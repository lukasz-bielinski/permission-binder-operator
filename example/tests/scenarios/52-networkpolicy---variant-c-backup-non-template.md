### Test 52: NetworkPolicy - Variant C (Backup Non-Template NetworkPolicy)

**Objective**: Verify operator backs up existing NetworkPolicy that doesn't match template pattern

**Setup**:
```bash
# Create namespace with existing NetworkPolicy that doesn't match template pattern
kubectl create namespace test-variant-c-ns

# Create existing NetworkPolicy WITHOUT template annotation (non-template policy)
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: custom-policy
  namespace: test-variant-c-ns
  # NO template annotation - this is a custom policy
spec:
  podSelector:
    matchLabels:
      app: custom-app
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: allowed-namespace
    ports:
    - protocol: TCP
      port: 8080
EOF

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

# Update ConfigMap to include test-variant-c-ns namespace
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-variant-c-ns-engineer,OU=Openshift,DC=example,DC=com
EOF
```

**Execution**:
```bash
# Wait for reconciliation
sleep 15

# Check status for backup variant
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-variant-c-ns")].state}'

# Verify PR contains backup file
PR_NUMBER=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-variant-c-ns")].prNumber}')
gh pr view $PR_NUMBER --repo lukasz-bielinski/tests-network-policies --json files --jq '.files[].path'
```

**Expected Result**:
- ✅ test-variant-c-ns namespace has backup PR state: "pr-created" or "pr-pending"
- ✅ Existing non-template NetworkPolicy backed up to Git repository
- ✅ Pull Request created with backup files
- ✅ PR contains backup file: `networkpolicies/DEV-cluster/test-variant-c-ns/custom-policy.yaml`
- ✅ PR contains template-based NetworkPolicy files (if templates exist)
- ✅ PR contains updated kustomization.yaml
- ✅ PR number, URL, and branch stored in PermissionBinder status
- ✅ PR exists on GitHub (verified via `gh` CLI)
- ✅ PR title indicates backup variant
- ✅ kustomization.yaml contains correct relative paths (no `../../` prefixes)

**Note**: Variant C differs from Variant B:
- Variant B: Backs up template-based NetworkPolicy (has template annotation)
- Variant C: Backs up non-template NetworkPolicy (no template annotation, custom policy)

---

