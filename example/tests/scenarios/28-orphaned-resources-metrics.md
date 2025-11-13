### Test 28: Orphaned Resources Metrics
**Objective**: Verify orphaned resources are tracked in metrics
**Steps**:
1. Record initial `permission_binder_orphaned_resources_total` value
2. Delete PermissionBinder CR (triggers SAFE MODE)
3. Wait for operator cleanup
4. Check updated metric value
5. Verify increase matches expected number of orphaned resources

**Expected Result**: Orphaned resources are properly tracked

