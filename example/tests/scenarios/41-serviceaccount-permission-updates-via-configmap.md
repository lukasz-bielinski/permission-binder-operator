### Test 41: ServiceAccount Permission Updates via ConfigMap

**Objective**: Verify ServiceAccount permissions update when role mapping changes in ConfigMap

**Background**:
When role assignments change in the PermissionBinder, existing ServiceAccount RoleBindings should be updated to reflect new permissions. This tests dynamic permission management.

**Setup**:
```bash
# Create PermissionBinder with initial permissions
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-permission-update
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: view  # Start with view (read-only)
    runtime: view
EOF

sleep 10

# Verify initial state
kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-deploy")) | "SA: \(.subjects[0].name) -> Role: \(.roleRef.name)"'
```

**Execution**:
```bash
# Step 1: Record initial permissions
INITIAL_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-deploy")) | .roleRef.name')

echo "Initial role for deploy SA: $INITIAL_ROLE"

if [ "$INITIAL_ROLE" == "view" ]; then
  echo "PASS: Initial role is 'view'"
else
  echo "FAIL: Initial role should be 'view', got: $INITIAL_ROLE"
fi

# Step 2: Update ServiceAccount mapping (upgrade permissions)
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-permission-update
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: admin  # UPGRADED: view -> admin
    runtime: edit  # UPGRADED: view -> edit
EOF

# Wait for reconciliation
sleep 15

# Step 3: Verify permissions updated
NEW_DEPLOY_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-deploy")) | .roleRef.name')
NEW_RUNTIME_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-runtime")) | .roleRef.name')

echo "New role for deploy SA: $NEW_DEPLOY_ROLE"
echo "New role for runtime SA: $NEW_RUNTIME_ROLE"

if [ "$NEW_DEPLOY_ROLE" == "admin" ]; then
  echo "PASS: Deploy SA upgraded to admin"
else
  echo "FAIL: Deploy SA should be admin, got: $NEW_DEPLOY_ROLE"
fi

if [ "$NEW_RUNTIME_ROLE" == "edit" ]; then
  echo "PASS: Runtime SA upgraded to edit"
else
  echo "FAIL: Runtime SA should be edit, got: $NEW_RUNTIME_ROLE"
fi

# Step 4: Verify SA UID unchanged (not recreated)
SA_UID=$(kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.uid}')
echo "ServiceAccount UID: $SA_UID"
# (Compare with initial UID from Step 1 if recorded)

# Step 5: Test permission downgrade
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-permission-update
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: view  # DOWNGRADED: admin -> view
    runtime: view  # DOWNGRADED: edit -> view
EOF

sleep 15

# Step 6: Verify permissions downgraded
FINAL_DEPLOY_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-deploy")) | .roleRef.name')
FINAL_RUNTIME_ROLE=$(kubectl get rolebinding -n test-namespace-001 -o json | jq -r '.items[] | select(.subjects[0].name | contains("sa-runtime")) | .roleRef.name')

echo "Final role for deploy SA: $FINAL_DEPLOY_ROLE"
echo "Final role for runtime SA: $FINAL_RUNTIME_ROLE"

if [ "$FINAL_DEPLOY_ROLE" == "view" ]; then
  echo "PASS: Deploy SA downgraded to view"
else
  echo "FAIL: Deploy SA should be view, got: $FINAL_DEPLOY_ROLE"
fi

if [ "$FINAL_RUNTIME_ROLE" == "view" ]; then
  echo "PASS: Runtime SA downgraded to view"
else
  echo "FAIL: Runtime SA should be view, got: $FINAL_RUNTIME_ROLE"
fi

# Step 7: Verify operator logs permission changes
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=100 | jq 'select(.message | contains("RoleBinding") or contains("updated")) | select(.namespace=="test-namespace-001")'

# Step 8: Functional test - verify actual permissions work
# Create test pod with deploy SA (now view permissions)
kubectl run test-pod-sa-perms -n test-namespace-001 \
  --image=bitnami/kubectl:latest \
  --serviceaccount=test-namespace-001-sa-deploy \
  --restart=Never \
  --command -- sleep 3600

kubectl wait --for=condition=Ready pod/test-pod-sa-perms -n test-namespace-001 --timeout=60s

# Try to create resource (should fail - only view permissions)
kubectl exec test-pod-sa-perms -n test-namespace-001 -- kubectl create configmap test-cm --from-literal=key=value 2>&1 | grep "Forbidden" && echo "PASS: View permissions enforced" || echo "FAIL: Should not have create permissions"

# Try to list resources (should succeed - view allows list)
kubectl exec test-pod-sa-perms -n test-namespace-001 -- kubectl get pods && echo "PASS: View permissions allow list" || echo "FAIL: Should have list permissions"

# Cleanup
kubectl delete pod test-pod-sa-perms -n test-namespace-001 --grace-period=0 --force
```

**Expected Result**:
- ✅ Permission upgrade (view -> admin) applied successfully
- ✅ Permission downgrade (admin -> view) applied successfully
- ✅ ServiceAccount not recreated (UID unchanged)
- ✅ RoleBinding updated in-place
- ✅ Changes logged in JSON format
- ✅ Actual permissions match configured permissions
- ✅ Multiple permission changes handled correctly
- ✅ No service disruption during updates

**Security Considerations**:
- Permission changes should be audited in logs
- Downgrade from admin to view should be immediate
- No temporary privilege escalation during updates

**Log Verification**:
```bash
# Expected log entries
{
  "level": "info",
  "message": "Updating RoleBinding permissions",
  "action": "update_rolebinding",
  "namespace": "test-namespace-001",
  "rolebinding": "...",
  "old_role": "view",
  "new_role": "admin",
  "serviceAccount": "test-namespace-001-sa-deploy"
}
```

---

