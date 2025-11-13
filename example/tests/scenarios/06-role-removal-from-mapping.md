### Test 6: Role Removal from Mapping
**Objective**: Verify operator removes RoleBindings when role is removed from mapping
**Steps**:
1. Remove role from PermissionBinder mapping
2. Verify all RoleBindings for that role are deleted
3. Verify other RoleBindings remain intact

**Expected Result**: RoleBindings for removed role deleted, others preserved

