### Test 16: Operator Permission Loss (Security)
**Objective**: Verify behavior when operator loses RBAC permissions
**Steps**:
1. Back up the operator ClusterRole `operator-manager-role` (`-${INSTANCE}` in isolated mode; fail loudly if it is missing) and remove its `rolebindings` rule with a JSON patch; wait until `kubectl auth can-i create rolebindings --as=system:serviceaccount:<operator-namespace>:operator-controller-manager` reports `no`
2. Trigger reconciliation by appending a whitelist entry for `${TEST_NS_PREFIX}test-16-rbac-loss` to the `permission-config` ConfigMap (a ConfigMap update is the event the reconciler acts on; PermissionBinder annotations are filtered out by its predicate)
3. Verify operator logs ERROR `Failed to create RoleBinding, entry will be retried` with a `forbidden` error
4. Verify the log line is parseable JSON with `error`, `namespace` and `role` fields (the target namespace is matched in the `error` text)
5. Verify graceful degradation: namespace `${TEST_NS_PREFIX}test-16-rbac-loss` created, RoleBinding `${TEST_NS_PREFIX}test-16-rbac-loss-admin` withheld, PermissionBinder condition `Processed=False` / `ProcessingIncomplete`
6. Restore permissions (`kubectl replace` of the resourceVersion-stripped backup, also armed in the EXIT trap) and touch the ConfigMap to leave the reconcile backoff
7. Verify operator recovers: RoleBinding `${TEST_NS_PREFIX}test-16-rbac-loss-admin` created, `Processed=True` / `ConfigMapProcessed`, Deployment Available

**Expected Result**: Clear error logging, graceful degradation, automatic recovery

