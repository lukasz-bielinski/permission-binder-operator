### Test 17: Partial Failure Recovery (Reliability)
**Objective**: Verify operator recovers from partial failures
**Steps**:
1. Add multiple entries to ConfigMap simultaneously
2. Make one entry invalid (e.g., non-existent ClusterRole that causes K8s rejection)
3. Verify operator processes valid entries successfully
4. Verify invalid entry is logged as ERROR
5. Verify partial success doesn't block other operations
6. Fix invalid entry and verify it gets processed

**Expected Result**: Partial failures don't cascade, valid operations succeed

