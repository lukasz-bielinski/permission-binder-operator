### Test 62: NetworkPolicy - High Frequency Reconciliation Stress Test

**Objective**: Validate operator stability and status updates when reconciliation interval is very short (`5s`) with frequent ConfigMap changes.

**Setup**:
```bash
# Ensure GitHub credentials Secret exists (with write access)

# Create PermissionBinder with short reconciliation interval and reduced sleep between namespaces
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-permissionbinder-networkpolicy-hfreq
  namespace: permissions-binder-operator
spec:
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: "edit"
  configMapName: "permission-config-hfreq"
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
    reconciliationInterval: "5s"
    batchProcessing:
      batchSize: 1
      sleepBetweenNamespaces: "0s"
      sleepBetweenBatches: "1s"
EOF

# Initial ConfigMap
data='CN=COMPANY-K8S-test-hfreq-engineer,OU=Openshift,DC=example,DC=com'
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config-hfreq
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
$(printf "%s" "$data")
EOF
```

**Execution**:
```bash
# Wait for initial reconciliation
echo "Waiting for initial reconciliation..."
sleep 15

# Capture first LastNetworkPolicyReconciliation timestamp
FIRST_TS=$(kubectl get permissionbinder test-permissionbinder-networkpolicy-hfreq -n permissions-binder-operator -o jsonpath='{.status.lastNetworkPolicyReconciliation}' 2>/dev/null)
echo "First reconciliation: $FIRST_TS"

# Rapidly update ConfigMap to simulate frequent changes
for i in {1..3}; do
  cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config-hfreq
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-hfreq-engineer,OU=Openshift,DC=example,DC=com
    CN=COMPANY-K8S-test-hfreq-$i-viewer,OU=Openshift,DC=example,DC=com
EOF
  sleep 6  # allow at least one interval to elapse

done

# Capture second reconciliation timestamp
SECOND_TS=$(kubectl get permissionbinder test-permissionbinder-networkpolicy-hfreq -n permissions-binder-operator -o jsonpath='{.status.lastNetworkPolicyReconciliation}' 2>/dev/null)
echo "Second reconciliation: $SECOND_TS"

# Compare timestamps and ensure operator remained available
kubectl get deployment operator-controller-manager -n permissions-binder-operator -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'
```

**Expected Result**:
- ✅ `LastNetworkPolicyReconciliation` updates between iterations (SECOND_TS > FIRST_TS)
- ✅ Multiple namespaces processed without errors or throttling deadlocks
- ✅ Operator deployment remains `Available=True`
- ✅ No repeated failures / warning storm in logs
- ✅ Git operations succeed despite frequent runs (PR branches unique)

**Cleanup**:
```bash
kubectl delete permissionbinder test-permissionbinder-networkpolicy-hfreq -n permissions-binder-operator
kubectl delete configmap permission-config-hfreq -n permissions-binder-operator
```

---
