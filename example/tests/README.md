# E2E Test Suite

## Overview

Comprehensive End-to-End test suite for the Permission Binder Operator covering all scenarios from `e2e-test-scenarios.md`.

## Test Scripts

### Main Scripts

#### `test-runner.sh` ⭐ **RECOMMENDED**
Modular test runner that allows running individual tests or all tests with proper cleanup between each test.

```bash
# List all available tests
./test-runner.sh list

# Run single test
./test-runner.sh 1

# Run range of tests  
./test-runner.sh 1-5

# Run all tests
./test-runner.sh all

# Run pre-test
./test-runner.sh pre

# Debug mode: Run test and preserve cluster state for analysis
./test-runner.sh 3 --no-cleanup
```

**Features:**
- ✅ Run individual tests in isolation
- ✅ Automatic cluster cleanup between tests
- ✅ Detailed logging to timestamped files
- ✅ Pass/Fail statistics with success rate
- ✅ Based on proven `run-complete-e2e-tests.sh` logic
- ✅ **Debug mode (`--no-cleanup`)**: Preserve cluster state after test for manual inspection

#### `run-complete-e2e-tests.sh`
Complete test suite that runs all tests sequentially without cleanup between tests (faster but less isolated).

```bash
# Run all tests in sequence
./run-complete-e2e-tests.sh
```

**Use when:**
- You want to run the full suite quickly
- Tests build on each other's state
- You're doing a final validation before release

### Helper Scripts

#### `cleanup-operator.sh`
Clean up all operator resources from the cluster.

```bash
./cleanup-operator.sh
```

#### `generate-large-configmap.sh`
Generate ConfigMap with 50+ entries for load testing (Test 24).

```bash
./generate-large-configmap.sh > /tmp/large-configmap.yaml
kubectl apply -f /tmp/large-configmap.yaml
```

#### `test-prometheus-metrics.sh`
Standalone test for Prometheus metrics verification.

```bash
./test-prometheus-metrics.sh
```

#### `test-concurrent.sh`
Test concurrent ConfigMap changes for race condition detection (Test 19).

```bash
./test-concurrent.sh
```

#### `test-whitelist-format.sh`
Test various whitelist entry formats.

```bash
./test-whitelist-format.sh
```

## Test Coverage

### Current Status: 29/34 Tests Implemented

#### ✅ Implemented (29 tests)
- Pre-Test: Initial State Verification
- Test 1-25: Core functionality, security, reliability
- Test 31-34: ServiceAccount management

#### 📋 TODO (5 tests)
Tests 26-30 are Prometheus metrics tests that need to be added:
- Test 26: Metrics Update on Role Mapping Changes
- Test 27: Metrics Update on ConfigMap Changes  
- Test 28: Orphaned Resources Metrics
- Test 29: ConfigMap Processing Metrics
- Test 30: Adoption Events Metrics

## Quick Start

### 1. Setup Environment

```bash
export KUBECONFIG=$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)
cd /home/pulse/workspace01/permission-binder-operator/example/tests
```

### 2. Run Tests

```bash
# Recommended: Run tests individually for debugging
./test-runner.sh 1      # Test role mapping
./test-runner.sh 2      # Test prefix changes
./test-runner.sh 3      # Test exclude list

# Run a group of related tests
./test-runner.sh 1-5    # Configuration tests
./test-runner.sh 13-16  # Security tests
./test-runner.sh 31-34  # ServiceAccount tests

# Run everything
./test-runner.sh all
```

### 3. Check Results

```bash
# View log file
cat /tmp/e2e-test-runner-*.log

# View specific test output
cat /tmp/test-1-output.log
```

## Test Categories

### Configuration Tests (1-6)
- Role mapping changes
- Prefix changes
- Exclude list
- ConfigMap additions/removals
- Role removal

### Reliability Tests (7-11)
- Namespace protection
- Safe mode deletion
- Operator restart recovery
- Conflict handling
- Invalid configuration

### Security Tests (13, 16)
- Non-existent ClusterRole validation
- Permission loss handling

### Recovery Tests (14-15, 17)
- Orphaned resource adoption
- Manual modification protection
- Partial failure recovery

### Observability Tests (18, 22-25)
- JSON structured logging
- Metrics endpoint
- Prometheus metrics collection

### Load Tests (19-21, 24)
- Concurrent changes
- ConfigMap corruption
- Network failures
- Large ConfigMap handling

### Finalizer Tests (23)
- Proper cleanup sequence

### ServiceAccount Tests (31-34)
- Creation and binding
- Custom naming patterns
- Idempotency
- Status tracking

## Best Practices

### For Development
```bash
# Test a specific feature you're working on
./test-runner.sh 1

# Quick iteration without cleanup (faster)
./test-runner.sh 1 --no-cleanup
```

### For CI/CD
```bash
# Run all tests with full isolation
./test-runner.sh all

# Or use the complete suite
./run-complete-e2e-tests.sh
```

### For Debugging Failures
```bash
# Run failing test individually
./test-runner.sh 3

# Check detailed logs
cat /tmp/test-3-output.log

# Check operator logs
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager
```

## Troubleshooting

### Test Fails Due to Timeout
- Increase sleep times in test
- Check operator pod is running: `kubectl get pods -n permissions-binder-operator`
- Check operator logs for errors

### Test Fails Due to Stale State
- Run with full cleanup: `./test-runner.sh X` (cleanup is default)
- Manually clean: `./cleanup-operator.sh`

### Cannot Find Test
```bash
# List available tests
./test-runner.sh list
```

### Tests Work Individually but Fail in Suite
- Tests may have dependencies on execution order
- Check if test modifies global state
- Ensure proper cleanup in test

## Adding New Tests

To add a new test:

1. Add test to `run-complete-e2e-tests.sh`:
```bash
# Test XX: Your Test Name
echo "Test XX: Your Test Name"
echo "------------------------"

# Test logic here
if [ condition ]; then
    pass_test "Test passed"
else
    fail_test "Test failed"
fi

echo ""
```

2. Test it individually:
```bash
./test-runner.sh XX
```

3. Add to documentation in `e2e-test-scenarios.md`

## Logs and Outputs

- Main log: `/tmp/e2e-test-runner-YYYYMMDD-HHMMSS.log`
- Individual test outputs: `/tmp/test-{N}-output.log`
- Temporary test scripts: `/tmp/single-test-{N}.sh`

## Debugging Failed Tests

When a test fails, use `--no-cleanup` flag to preserve cluster state:

```bash
# Run failing test with debug mode
./test-runner.sh 3 --no-cleanup
```

This will:
- Run the test normally
- **Skip cleanup** after test completes
- Display helpful commands for manual inspection

Example output:
```
❌ Test 3 FAILED

🔍 Debug mode: Cluster state preserved for analysis
   - Check namespaces: kubectl get ns
   - Check RoleBindings: kubectl get rolebindings -A -l permission-binder.io/managed-by
   - Check operator logs: kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=50
   - Check PermissionBinder: kubectl get permissionbinder -n permissions-binder-operator -o yaml
   - Cleanup when done: cd /path/to/tests && ./cleanup-operator.sh
```

**Typical debugging workflow:**
1. Run test with `--no-cleanup`
2. Use suggested kubectl commands to inspect cluster state
3. Check operator logs for errors
4. Verify CR spec and status
5. Fix the issue
6. Run `./cleanup-operator.sh` before retesting

## Contributing

When adding tests, ensure:
- Test is self-contained (own setup/cleanup)
- Clear pass/fail criteria
- Proper logging with `pass_test` and `fail_test`
- Documentation in `e2e-test-scenarios.md`

