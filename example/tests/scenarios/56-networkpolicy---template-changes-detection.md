### Test 56: NetworkPolicy - Template Changes Detection

**Objective**: Verify operator detects changes in NetworkPolicy templates and reprocesses namespaces

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

# Create ConfigMap with test namespace
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-template-changes-engineer,OU=Openshift,DC=example,DC=com
EOF

# Wait for initial PR creation
sleep 30

# Get PR number and merge it
PR_NUMBER=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-template-changes")].prNumber}')
gh pr merge $PR_NUMBER --repo lukasz-bielinski/tests-network-policies --merge

# Wait for merge to complete
sleep 10
```

**Execution**:
```bash
# Modify template in Git repository (add a new rule or change existing one)
# This simulates template change that should trigger reprocessing

# Option 1: Modify template file directly in repository
# Option 2: Create a new template file
# Option 3: Delete a template file

# For this test, we'll modify the template to add a new rule
# (This requires direct Git access or GitHub API)

# Wait for periodic reconciliation (or trigger reconciliation manually)
# Check operator logs for template change detection
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | grep -i "template.*change\|reprocess.*namespace"

# Check if new PR is created for reprocessed namespace
sleep 60  # Wait for periodic reconciliation (or reduce reconciliationInterval for testing)

# Check PermissionBinder status for new PR
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-template-changes")].prNumber}'
```

**Expected Result**:
- ✅ Operator detects template changes during periodic reconciliation
- ✅ Operator logs template change detection
- ✅ Operator reprocesses namespaces that use changed templates
- ✅ New PR created for reprocessed namespace (if template changed)
- ✅ PR contains updated NetworkPolicy files based on new template
- ✅ Template change detection logged with audit trail
- ✅ Periodic reconciliation timestamp updated

**Note**: Template change detection:
- Runs during periodic reconciliation (reconciliationInterval: 1h)
- Compares template files in Git with previous state
- Reprocesses all namespaces that use changed templates
- Creates new PRs for updated NetworkPolicies
- Logs template changes for audit trail

**Limitation**: This test may require:
- Manual template modification in Git repository
- Or reducing reconciliationInterval for faster testing
- Or triggering reconciliation manually (if supported)

---

