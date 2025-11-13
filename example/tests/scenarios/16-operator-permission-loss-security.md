### Test 16: Operator Permission Loss (Security)
**Objective**: Verify behavior when operator loses RBAC permissions
**Steps**:
1. Remove specific RBAC permission from operator ServiceAccount (e.g., rolebindings.create)
2. Trigger reconciliation (add ConfigMap entry)
3. Verify operator logs ERROR with proper context
4. Verify JSON logs are parseable and contain error details
5. Restore permissions
6. Verify operator recovers and creates pending resources

**Expected Result**: Clear error logging, graceful degradation, automatic recovery

