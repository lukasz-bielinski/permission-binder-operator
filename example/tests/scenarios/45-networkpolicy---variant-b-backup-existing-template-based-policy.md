### Test 45: NetworkPolicy - Variant B (Backup Existing Template-based Policy)

**Objective**: Verify operator backs up existing template-based NetworkPolicy

**Setup**:
```bash
# Create namespace with existing NetworkPolicy matching template pattern
kubectl create namespace test-backup-ns

# Create existing NetworkPolicy that matches template pattern
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: test-backup-ns-deny-all-ingress
  namespace: test-backup-ns
  annotations:
    network-policy.permission-binder.io/template: "deny-all-ingress.yaml"
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress: []
EOF

# Update ConfigMap to include test-backup-ns namespace
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
    CN=COMPANY-K8S-test-backup-ns-engineer,OU=Openshift,DC=example,DC=com
EOF
```

**Execution**:
```bash
# Wait for reconciliation
sleep 15

# Check status for backup variant
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-backup-ns")].state}'
```

**Expected Result**:
- ✅ test-backup-ns namespace has backup PR state: "pr-created" or "pr-pending"
- ✅ Existing NetworkPolicy backed up to Git repository
- ✅ Pull Request created with backup files
- ✅ PR number, URL, and branch stored in PermissionBinder status
- ✅ PR exists on GitHub (verified via `gh` CLI)
- ✅ PR contains expected backup files:
  - `networkpolicies/DEV-cluster/test-backup-ns/test-backup-ns-deny-all-ingress.yaml`
  - `networkpolicies/DEV-cluster/kustomization.yaml` (updated)
- ✅ PR title indicates backup variant
- ✅ kustomization.yaml contains correct relative paths (no `../../` prefixes)

---

