### Test 47: NetworkPolicy - Exclude Lists

**Objective**: Verify operator respects global exclude list for NetworkPolicy processing

**Execution**:
```bash
# Add excluded namespace to ConfigMap
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
    CN=COMPANY-K8S-kube-system-engineer,OU=Openshift,DC=example,DC=com
EOF

# Wait for reconciliation
sleep 10

# Verify kube-system is excluded from NetworkPolicy processing
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[*].namespace}'
```

**Expected Result**:
- ✅ kube-system is NOT in NetworkPolicy status (excluded by explicit exclude list)
- ✅ test-app and test-app-2 are still processed (not excluded)
- ✅ Exclude list patterns (^kube-.*, ^openshift-.*) are respected

---

