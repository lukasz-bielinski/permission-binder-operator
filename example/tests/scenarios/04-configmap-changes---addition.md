### Test 4: ConfigMap Changes - Addition
**Objective**: Verify operator processes new ConfigMap entries
**Steps**:
1. Add new entry to ConfigMap with valid format
2. Verify operator creates corresponding RoleBinding
3. Verify namespace is created if it doesn't exist
4. Verify RoleBinding has correct annotations and labels

**Expected Result**: New RoleBinding created with proper metadata

