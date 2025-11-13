### Test 23: Finalizer Behavior Verification
**Objective**: Verify finalizer ensures proper cleanup sequence
**Steps**:
1. Create PermissionBinder and verify finalizer is added
2. Initiate deletion (kubectl delete)
3. Verify PermissionBinder enters "Terminating" state
4. Verify cleanup logic executes (orphaned annotations added)
5. Verify finalizer is removed after cleanup
6. Verify PermissionBinder is fully deleted

**Expected Result**: Proper cleanup sequence, no stuck finalizers

