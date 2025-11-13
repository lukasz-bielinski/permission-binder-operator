### Test 48: NetworkPolicy - Stale PR Detection

**Objective**: Verify operator detects stale Pull Requests

**Execution**:
```bash
# Check for stale PR states
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[*].state}'

# If stale PR found, verify CreatedAt timestamp
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.state=="pr-stale")].createdAt}'
```

**Expected Result**:
- ✅ Stale PRs detected (state: "pr-stale")
- ✅ Stale PRs have CreatedAt timestamp for tracking
- ✅ Stale PR detection runs based on configured threshold

**Note**: In real scenario, this test requires waiting for `stalePRThreshold`. Test checks if stale PRs exist.

---

