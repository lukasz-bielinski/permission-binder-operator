### Test 50: NetworkPolicy - Metrics Verification

**Objective**: Verify NetworkPolicy Prometheus metrics are correctly incremented

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
    CN=COMPANY-K8S-test-metrics-engineer,OU=Openshift,DC=example,DC=com
EOF
```

**Execution**:
```bash
# Get initial metric values
INITIAL_PR_CREATED=$(curl -s http://localhost:8080/metrics | grep 'permission_binder_networkpolicy_prs_created_total' | grep 'cluster="DEV-cluster"' | awk '{print $2}' || echo "0")

# Wait for reconciliation and PR creation
sleep 30

# Get metric values after PR creation
FINAL_PR_CREATED=$(curl -s http://localhost:8080/metrics | grep 'permission_binder_networkpolicy_prs_created_total' | grep 'cluster="DEV-cluster"' | awk '{print $2}' || echo "0")

# Verify metrics incremented
# Check permission_binder_networkpolicy_prs_created_total
# Check permission_binder_networkpolicy_pr_creation_errors_total (should be 0)
# Check permission_binder_networkpolicy_template_validation_errors_total (should be 0)
```

**Expected Result**:
- ✅ `permission_binder_networkpolicy_prs_created_total{cluster="DEV-cluster",namespace="test-metrics",variant="new"}` incremented by 1
- ✅ `permission_binder_networkpolicy_pr_creation_errors_total` remains 0 (no errors)
- ✅ `permission_binder_networkpolicy_template_validation_errors_total` remains 0 (no validation errors)
- ✅ Metrics accessible via `/metrics` endpoint
- ✅ Metrics have correct labels (cluster, namespace, variant)

**Note**: This test requires:
- Operator metrics endpoint accessible (port-forward or direct access)
- Prometheus scraping configured (optional, for verification)
- PR creation to succeed (for positive metric increment)

---

