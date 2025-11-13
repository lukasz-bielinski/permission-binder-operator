### Test 5: ConfigMap Changes - Removal
**Objective**: Verify operator handles ConfigMap entry removal
**Steps**:
1. Remove entry from ConfigMap
2. Verify corresponding RoleBinding is removed
3. Verify namespace is NOT deleted (only annotated)

**Expected Result**: RoleBinding removed, namespace preserved with annotation

