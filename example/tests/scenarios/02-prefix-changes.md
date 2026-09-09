### Test 2: Prefix Changes
**Objective**: Verify operator handles prefix changes correctly
**Steps**:
1. Change prefix from `COMPANY-K8S` to `NEW-PREFIX`
2. Verify the operator processed the new prefix (`NEW-PREFIX` in the operator logs)
3. Add a new ConfigMap entry under the new prefix and force reconciliation
4. Verify the new namespace and its RoleBinding are created (owned by this instance's CR)
5. Restore the original `COMPANY-K8S` prefix and remove the new-prefix entry

**Expected Result**: Operator processes the new prefix; the new-prefix ConfigMap entry yields a namespace and RoleBinding; the prefix is restored afterwards

