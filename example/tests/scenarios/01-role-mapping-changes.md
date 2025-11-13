### Test 1: Role Mapping Changes
**Objective**: Verify operator correctly handles changes in role mapping
**Steps**:
1. Create new ClusterRole (e.g., `clusterrole-developer`)
2. Add new role to PermissionBinder mapping
3. Verify operator creates RoleBindings for new role in all managed namespaces
4. Verify RoleBindings have correct ClusterRole reference

**Expected Result**: 6 new RoleBindings created (1 role × 6 namespaces)

