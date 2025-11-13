### Test 13: Non-Existent ClusterRole (Security)
**Objective**: Verify operator handles missing ClusterRoles safely
**Steps**:
1. Add role to PermissionBinder mapping that references non-existent ClusterRole
2. Add corresponding entry to ConfigMap
3. Verify operator creates RoleBinding despite missing ClusterRole
4. Verify WARNING is logged with security_impact=high
5. Verify JSON log contains: clusterRole, severity, action_required, impact
6. Create the ClusterRole later and verify RoleBinding starts working

**Expected Result**: RoleBinding created, clear WARNING logged, no reconciliation failure

