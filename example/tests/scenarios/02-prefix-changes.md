### Test 2: Prefix Changes
**Objective**: Verify a prefix-only spec change is processed on its own (issue #94): old-prefix RoleBindings are removed, entries under the new prefix are applied, and no ConfigMap edit or forced reconciliation is needed in between
**Steps**:
1. Record the baseline RoleBindings owned by the CR under `COMPANY-K8S` (fixture contract: at least one)
2. Seed a whitelist entry under `NEW-PREFIX` BEFORE the prefix change and wait until `status.lastProcessedConfigMapVersion` equals the ConfigMap's live `resourceVersion`; verify the entry is inert under `COMPANY-K8S` (its namespace does not exist)
3. Change `spec.prefixes` from `COMPANY-K8S` to `NEW-PREFIX` - nothing else: no ConfigMap edit, no annotation poke
4. Wait until the `Processed` condition's `observedGeneration` and `status.lastProcessedGeneration` reach the new generation, then verify:
   - every baseline RoleBinding is gone (group matches none of the new prefixes)
   - the new-prefix entry yields its namespace and RoleBinding (owned by this instance's CR)
   - the operator logs show the old-prefix entries rejected with `available prefixes: [NEW-PREFIX]`
   - `status.lastProcessedConfigMapVersion` is unchanged (no ConfigMap change was involved)
5. Restore `COMPANY-K8S`, remove the new-prefix entry, wait for the new generation and ConfigMap version to be consumed; verify the baseline RoleBindings are back and the new-prefix RoleBinding is gone

**Expected Result**: The prefix-only spec change alone is reconciled - old-prefix RoleBindings are removed, new-prefix ones are created, `observedGeneration` advances - and the restore reverses it the same way
