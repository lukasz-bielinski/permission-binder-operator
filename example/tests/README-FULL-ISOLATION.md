# E2E Tests - Full Isolation Mode

## Problem

Standard `run-all-individually.sh` may not always provide **true** full isolation between tests:
- Same operator pod across all tests
- Accumulated state in controller
- Kubernetes API cache
- Metrics are not reset

**Result:** Flaky tests - tests pass on re-run but fail in long runs.

## Solution: `run-tests-full-isolation.sh`

New script providing **GUARANTEED** full isolation for each test:

```
Test 1:
  1. CLEANUP: Remove operator + CRD + all namespaces
  2. DEPLOY:  Deploy fresh operator (new pod!)
  3. RUN:     Execute test
  
Test 2:
  1. CLEANUP: Remove operator + CRD + all namespaces
  2. DEPLOY:  Deploy fresh operator (new pod!)
  3. RUN:     Execute test

... (repeat for each test)
```

## Usage

### 1. All tests (pre + 1-43)

```bash
cd example/tests
./run-tests-full-isolation.sh
```

**Duration:** ~80-100 minutes (42 tests × 2-3 min)

### 2. Single test

```bash
./run-tests-full-isolation.sh 3
```

**Duration:** ~2 minutes

### 3. Selected tests

```bash
./run-tests-full-isolation.sh 3 7 11 16
```

**Duration:** ~8 minutes (4 tests × 2 min)

### 4. Re-run failed tests

If you have failed tests from a previous run:

```bash
# From yesterday's run, failed: 3, 7, 11, 16, 21, 26, 29
./run-tests-full-isolation.sh 3 7 11 16 21 26 29
```

**Duration:** ~14 minutes (7 tests × 2 min)

## Output and Logs

### Live Output

```
═════════════════════════════════════════════════════════════════
[1/7] Test 3: Exclude List Changes
═════════════════════════════════════════════════════════════════

🧹 Step 1/3: Cleaning cluster...
   ✅ Cluster cleaned
📦 Step 2/3: Deploying fresh operator...
   ✅ Operator ready
      Pod: operator-controller-manager-6d888866dd-h9jms
      Started: 2025-10-30T04:41:15Z
▶️  Step 3/3: Running test 3...

✅ Test 3 PASSED
✅ PASS: Namespace correctly not created (excluded by excludeList)
✅ PASS: No RoleBindings created for excluded namespace
✅ PASS: Valid namespace still exists

Progress: 1/7 (✅ 1 passed, ❌ 0 failed)
```

### Final Summary

```
═════════════════════════════════════════════════════════════════
📊 FINAL SUMMARY
═════════════════════════════════════════════════════════════════

✅ Test 3: Exclude List Changes - PASSED (pod: ...h9jms)
✅ Test 7: Namespace Protection - PASSED (pod: ...srxwx)
✅ Test 11: Invalid Configuration Handling - PASSED (pod: ...d5qtv)
✅ Test 16: Operator Permission Loss - PASSED (pod: ...djt6t)
✅ Test 21: Network Failure Simulation - PASSED (pod: ...xlfcc)
✅ Test 26: Metrics Update on Role Mapping - PASSED (pod: ...htxkm)
✅ Test 29: ConfigMap Processing Metrics - PASSED (pod: ...r7sbb)

═════════════════════════════════════════════════════════════════
Total Tests: 7
✅ Passed: 7
❌ Failed: 0
Success Rate: 100.0%

Results log: /tmp/e2e-full-isolation-20251030-053104.log
Individual logs:
  - Cleanup: /tmp/cleanup-<test_id>.log
  - Deploy:  /tmp/deploy-<test_id>.log
  - Test:    /tmp/test-<test_id>-isolated.log

Completed: Thu Oct 30 05:41:44 AM CET 2025
═════════════════════════════════════════════════════════════════

🎉 ALL TESTS PASSED!
```

### Log Files

After running, you'll find logs in `/tmp/`:

```bash
# Main results log
/tmp/e2e-full-isolation-20251030-053104.log

# Per-test logs
/tmp/cleanup-3.log      # Cleanup output for Test 3
/tmp/deploy-3.log       # Deploy output for Test 3
/tmp/test-3-isolated.log # Test execution output for Test 3

# (Repeat for each test)
```

## When to Use Which Runner?

| Runner | Isolation | Time | Use Case |
|--------|----------|------|----------|
| `test-runner.sh` | None | Seconds | Quick test of single scenario |
| `run-all-individually.sh` | Medium | ~40 min | Standard test run (OK for most cases) |
| `run-tests-full-isolation.sh` | **Full** | ~80-100 min | **Pre-release validation, debugging flaky tests** |

## When to Use Full Isolation?

✅ **Use when:**
- Debugging flaky tests (tests that sometimes fail)
- Pre-release validation (before v1.x.0)
- Tests failed in nightly run but passed on re-run
- You want 100% confidence that operator works stably
- Checking if cleanup works correctly

❌ **Don't use when:**
- Quick development iteration
- Debugging specific test (use `test-runner.sh <test_id>`)
- Limited time (use `run-all-individually.sh`)

## Differences vs `run-all-individually.sh`

| Feature | run-all-individually.sh | run-tests-full-isolation.sh |
|---------|-------------------------|------------------------------|
| Cleanup per test | ✅ | ✅ |
| Deploy per test | ✅ | ✅ |
| **Fresh pod per test** | ⚠️  May use cache | ✅ **Guaranteed** |
| **Verify pod running** | ✅ | ✅ |
| **Detailed logs per step** | ❌ | ✅ (cleanup, deploy, test) |
| **Pod name tracking** | ❌ | ✅ In summary |
| **Colored output** | ❌ | ✅ |
| Time per test | ~1 min | ~2 min |
| **Use case** | Standard CI/CD | **Pre-release, debugging** |

## Examples

### Example 1: Quick pre-release check

```bash
# Check only "problematic" tests before release
./run-tests-full-isolation.sh 16 21 26 29

# Security + network + metrics tests (often flaky)
```

### Example 2: Debug specific failed test

```bash
# Test 16 failed yesterday, check with full isolation
./run-tests-full-isolation.sh 16

# Check logs if it fails again
cat /tmp/cleanup-16.log
cat /tmp/deploy-16.log
cat /tmp/test-16-isolated.log
```

### Example 3: Nightly full validation

```bash
# Cron job - full validation every night
0 2 * * * cd /path/to/tests && ./run-tests-full-isolation.sh > /var/log/e2e-nightly.log 2>&1
```

### Example 4: CI/CD Integration

```yaml
# .github/workflows/e2e-full-isolation.yml
name: E2E Tests - Full Isolation
on:
  schedule:
    - cron: '0 2 * * *'  # Nightly
  workflow_dispatch:     # Manual trigger

jobs:
  e2e-full-isolation:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v3
      - name: Run E2E Tests (Full Isolation)
        run: |
          cd example/tests
          ./run-tests-full-isolation.sh
```

## Troubleshooting

### Problem: Test fails only in full isolation mode

**Diagnosis:**
- Test has dependency on previous state
- Test doesn't wait for async operations
- Race condition in test

**Fix:**
Check test logic - should be **idempotent** and **self-contained**.

### Problem: Cleanup timeout

**Diagnosis:**
Namespace stuck in `Terminating` state.

**Fix:**
```bash
# Manual force cleanup
kubectl get ns | grep Terminating
kubectl delete namespace <ns> --force --grace-period=0
```

### Problem: Deploy fails (ImagePullBackOff)

**Diagnosis:**
Image doesn't exist or lacks multi-arch support.

**Fix:**
```bash
# Check Docker Hub
docker manifest inspect lukaszbielinski/permission-binder-operator:1.5.0

# Verify both amd64 and arm64 exist
```

## Best Practices

1. **Always use for pre-release validation**
   ```bash
   # Before tagging v1.x.0
   ./run-tests-full-isolation.sh
   ```

2. **Run overnight for full validation**
   ```bash
   nohup ./run-tests-full-isolation.sh > /tmp/nightly.log 2>&1 &
   ```

3. **Debug flaky tests individually**
   ```bash
   # Run flaky test 10 times
   for i in {1..10}; do
     echo "Run $i"
     ./run-tests-full-isolation.sh 16
   done
   ```

4. **Monitor resources during run**
   ```bash
   # Terminal 1
   ./run-tests-full-isolation.sh
   
   # Terminal 2
   watch -n 5 'kubectl get pods -A'
   ```

## Metrics and Performance

**Typical run time breakdown per test:**
- Cleanup: 30-40s
- Deploy: 20-30s
- Test execution: 30-60s
- **Total per test:** ~2 minutes

**Full suite (42 tests):**
- Best case: 80 minutes
- Typical: 90 minutes
- Worst case: 100 minutes

## Conclusion

`run-tests-full-isolation.sh` is the **gold standard** for E2E testing:
- ✅ Guaranteed full isolation
- ✅ Fresh pod per test (no cache!)
- ✅ Detailed logging
- ✅ Perfect for pre-release validation

**Use before every release to ensure 100% confidence that the operator works stably!**

