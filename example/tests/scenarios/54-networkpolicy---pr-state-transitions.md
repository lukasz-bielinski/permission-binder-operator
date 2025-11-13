### Test 54: NetworkPolicy - PR State Transitions

**Objective**: Verify PR state transitions correctly through all states

**Setup**:
```bash
# Create GitHub GitOps credentials Secret from dedicated file
# File location: temp/github-gitops-credentials-secret.yaml
kubectl apply -f temp/github-gitops-credentials-secret.yaml

# Create PermissionBinder with NetworkPolicy enabled (auto-merge disabled to observe state transitions)
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
    CN=COMPANY-K8S-test-state-transitions-engineer,OU=Openshift,DC=example,DC=com
EOF
```

**Execution**:
```bash
# Wait for PR creation
sleep 15

# Check initial state (should be pr-created or pr-pending)
INITIAL_STATE=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-state-transitions")].state}')
echo "Initial state: $INITIAL_STATE"

# Check CreatedAt timestamp
CREATED_AT=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-state-transitions")].createdAt}')
echo "CreatedAt: $CREATED_AT"

# Get PR number and manually merge PR on GitHub
PR_NUMBER=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-state-transitions")].prNumber}')
gh pr merge $PR_NUMBER --repo lukasz-bielinski/tests-network-policies --merge

# Wait for operator to detect merged state (periodic reconciliation or next reconciliation)
sleep 30

# Check final state (should be pr-merged)
FINAL_STATE=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-state-transitions")].state}')
echo "Final state: $FINAL_STATE"
```

**Expected Result**:
- ✅ Initial state: "pr-created" or "pr-pending"
- ✅ CreatedAt timestamp is set when PR is created
- ✅ State transitions: pr-created → pr-pending → pr-merged (when PR merged)
- ✅ State updates correctly when PR is merged on GitHub
- ✅ PR number, URL, and branch remain consistent across state transitions
- ✅ State transitions are logged with audit trail
- ✅ Timestamp is preserved during state transitions

**Note**: State transitions depend on:
- PR creation: pr-created
- PR pending: pr-pending
- PR merged: pr-merged (detected via periodic reconciliation or next reconciliation)
- PR stale: pr-stale (if PR not merged within threshold)
- PR error: pr-error (if PR creation fails)

---

