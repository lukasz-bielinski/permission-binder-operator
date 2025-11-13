### Test 2: Prefix Changes
**Objective**: Verify operator handles prefix changes correctly
**Steps**:
1. Change prefix from `COMPANY-K8S` to `NEW_PREFIX`
2. Add new ConfigMap entry with new prefix
3. Verify operator processes new prefix correctly
4. Verify old RoleBindings with old prefix are removed
5. Verify new RoleBindings with new prefix are created

**Expected Result**: Old RoleBindings removed, new ones created with correct prefix

