### Test 42: RoleBindings with Hyphenated Roles (Bug Fix v1.5.2)

**Objective**: Verify operator correctly handles RoleBindings with hyphenated role names (e.g., "read-only", "cluster-admin")

**Background**:
Previous bug (fixed in v1.5.2): RoleBindings with roles containing hyphens were incorrectly deleted as obsolete because `extractRoleFromRoleBindingName()` only extracted the last segment after splitting by hyphens. For example, "production-read-only" would extract "only" instead of "read-only", causing the RoleBinding to be deleted when "only" wasn't found in the role mapping.

**Setup**:
```bash
# Create PermissionBinder with hyphenated role mappings
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-hyphenated-roles
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: edit
    "read-only": view  # Role with hyphen
    "cluster-admin": cluster-admin  # Role with hyphen
    admin: admin
EOF

# Create ConfigMap entries with hyphenated roles
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |-
    CN=COMPANY-K8S-test-ns-read-only,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-test-ns-cluster-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-test-ns-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
EOF

sleep 10
```

**Execution**:
```bash
# Step 1: Verify RoleBindings created for hyphenated roles
kubectl get rolebinding -n test-ns -o json | jq -r '.items[] | select(.metadata.annotations."permission-binder.io/managed-by" == "permission-binder-operator") | "\(.metadata.name) -> \(.roleRef.name)"'

# Verify "read-only" RoleBinding exists
kubectl get rolebinding test-ns-read-only -n test-ns && echo "PASS: read-only RoleBinding exists" || echo "FAIL: read-only RoleBinding missing"

# Verify "cluster-admin" RoleBinding exists
kubectl get rolebinding test-ns-cluster-admin -n test-ns && echo "PASS: cluster-admin RoleBinding exists" || echo "FAIL: cluster-admin RoleBinding missing"

# Step 2: Verify AnnotationRole annotation stores full role name
READ_ONLY_ROLE=$(kubectl get rolebinding test-ns-read-only -n test-ns -o jsonpath='{.metadata.annotations.permission-binder\.io/role}')
CLUSTER_ADMIN_ROLE=$(kubectl get rolebinding test-ns-cluster-admin -n test-ns -o jsonpath='{.metadata.annotations.permission-binder\.io/role}')

echo "AnnotationRole for read-only: $READ_ONLY_ROLE"
echo "AnnotationRole for cluster-admin: $CLUSTER_ADMIN_ROLE"

if [ "$READ_ONLY_ROLE" == "read-only" ]; then
  echo "PASS: AnnotationRole correctly stores 'read-only'"
else
  echo "FAIL: AnnotationRole should be 'read-only', got: $READ_ONLY_ROLE"
fi

if [ "$CLUSTER_ADMIN_ROLE" == "cluster-admin" ]; then
  echo "PASS: AnnotationRole correctly stores 'cluster-admin'"
else
  echo "FAIL: AnnotationRole should be 'cluster-admin', got: $CLUSTER_ADMIN_ROLE"
fi

# Step 3: Trigger reconciliation (this previously caused deletion bug)
kubectl annotate permissionbinder test-hyphenated-roles -n permissions-binder-operator trigger-reconcile="$(date +%s)" --overwrite

sleep 10

# Step 4: Verify RoleBindings NOT deleted (bug fix verification)
kubectl get rolebinding test-ns-read-only -n test-ns && echo "PASS: read-only RoleBinding NOT deleted after reconciliation" || echo "FAIL: read-only RoleBinding was deleted!"

kubectl get rolebinding test-ns-cluster-admin -n test-ns && echo "PASS: cluster-admin RoleBinding NOT deleted after reconciliation" || echo "FAIL: cluster-admin RoleBinding was deleted!"

# Step 5: Verify no "Deleted obsolete RoleBinding" logs for hyphenated roles
OBsolete_LOGS=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=100 | jq -r 'select(.message | contains("Deleted obsolete RoleBinding")) | select(.name | contains("read-only") or contains("cluster-admin"))')

if [ -z "$OBsolete_LOGS" ]; then
  echo "PASS: No incorrect deletion logs for hyphenated roles"
else
  echo "FAIL: Found incorrect deletion logs: $OBsolete_LOGS"
fi

# Step 6: Test role removal from mapping (should delete correctly)
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-hyphenated-roles
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: edit
    admin: admin
    # REMOVED: "read-only" and "cluster-admin"
EOF

sleep 10

# Verify hyphenated role RoleBindings ARE deleted when role removed from mapping
kubectl get rolebinding test-ns-read-only -n test-ns 2>&1 | grep "NotFound" && echo "PASS: read-only RoleBinding correctly deleted when role removed" || echo "FAIL: read-only RoleBinding should be deleted"

kubectl get rolebinding test-ns-cluster-admin -n test-ns 2>&1 | grep "NotFound" && echo "PASS: cluster-admin RoleBinding correctly deleted when role removed" || echo "FAIL: cluster-admin RoleBinding should be deleted"

# Verify engineer RoleBinding still exists (not removed)
kubectl get rolebinding test-ns-engineer -n test-ns && echo "PASS: engineer RoleBinding preserved (role still in mapping)" || echo "FAIL: engineer RoleBinding incorrectly deleted"
```

**Expected Result**:
- ✅ RoleBindings with hyphenated roles created successfully
- ✅ AnnotationRole annotation stores full role name (e.g., "read-only", not "only")
- ✅ RoleBindings NOT deleted incorrectly during reconciliation
- ✅ No "Deleted obsolete RoleBinding" logs for hyphenated roles when roles exist in mapping
- ✅ RoleBindings correctly deleted when role removed from mapping
- ✅ Other RoleBindings preserved when specific role removed
- ✅ Backward compatibility: Works with existing RoleBindings without AnnotationRole

**Related Bug**: Fixed in v1.5.2 - RoleBinding deletion check for hyphenated roles

---

