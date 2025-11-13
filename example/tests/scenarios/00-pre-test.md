### Pre-Test: Initial State Verification
**Objective**: Verify operator is running and basic functionality works before starting tests
**Steps**:
1. Check operator pod is running
2. Verify JSON structured logging is working
3. Verify finalizer is present on PermissionBinder CR
4. Confirm operator deployment is healthy

**Expected Result**: Operator is running and healthy, ready for testing

**Note**: This is a sanity check performed before the main test suite.

---

