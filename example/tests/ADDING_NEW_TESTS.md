# Adding New E2E Tests

## Overview

This guide explains how to add new E2E tests to the test suite. The structure is designed to be **clear, maintainable, and easy to extend**.

## Test Structure

Each test consists of **two files**:
1. **Scenario file** (`scenarios/XX-test-name.md`) - Documentation describing what the test does
2. **Implementation file** (`test-implementations/test-XX-test-name.sh`) - Bash script with actual test code

**Mapping**: `scenarios/44-networkpolicy-variant-a.md` ↔ `test-implementations/test-44-networkpolicy-variant-a.sh`

## Step-by-Step Guide

### Step 1: Determine Test Number

Check the highest test number:
```bash
ls -1 example/tests/test-implementations/ | grep -E "^test-[0-9]+" | sort -V | tail -1
```

Next test number = highest + 1 (currently: 48, so next would be 49)

### Step 2: Create Scenario File

Create `example/tests/scenarios/XX-test-name.md`:

```markdown
### Test XX: Test Name

**Objective**: Brief description of what this test verifies

**Setup**:
```bash
# Commands to set up test environment
```

**Execution**:
```bash
# Commands to execute the test
```

**Expected Result**:
- ✅ What should happen
- ✅ What should be verified
```

**Naming convention**: Use lowercase with hyphens, e.g., `49-new-feature-test.md`

### Step 3: Create Implementation File

Create `example/tests/test-implementations/test-XX-test-name.sh`:

```bash
#!/bin/bash
# Test XX: Test Name
# Source common functions (SCRIPT_DIR should be set by parent script)
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# Test XX: Test Name
# ============================================================================
echo "Test XX: Test Name"
echo "------------------"

# Your test code here
# Use helper functions: pass_test(), fail_test(), info_log(), kubectl_retry()

# Example:
if kubectl_retry kubectl get namespace test-ns >/dev/null 2>&1; then
    pass_test "Namespace created successfully"
else
    fail_test "Namespace not created"
fi

echo ""
```

**Important**:
- Always source `test-common.sh` at the top
- Use helper functions: `pass_test()`, `fail_test()`, `info_log()`, `kubectl_retry()`
- Use `$NAMESPACE` variable (set by parent script)
- End with `echo ""` for readability

### Step 4: Update Test List

Add test to `run-tests-full-isolation.sh`:

```bash
# In TEST_FILES array, add:
"test-XX-test-name.sh"
```

### Step 5: Update Documentation

1. **Update `e2e-test-scenarios.md`**:
   - Add test to appropriate category
   - Update test count if needed

2. **Update `scenarios/README.md`**:
   - Add link to new scenario file

3. **Update main `README.md`**:
   - Update test count if needed

### Step 6: Test Your Test

```bash
cd example/tests
./run-tests-full-isolation.sh XX
```

## Test Template

Use this template for new tests:

```bash
#!/bin/bash
# Test XX: Test Name - Brief Description
# Source common functions (SCRIPT_DIR should be set by parent script)
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# Test XX: Test Name
# ============================================================================
echo "Test XX: Test Name"
echo "------------------"

# Setup: Create required resources
info_log "Setting up test environment..."

# Your setup code here

# Execution: Run test steps
info_log "Executing test steps..."

# Your test code here
# Use pass_test() and fail_test() for assertions

# Cleanup (if needed)
info_log "Cleaning up test resources..."

# Your cleanup code here

echo ""
```

## Helper Functions

Available in `test-common.sh`:

- **`pass_test "message"`** - Mark test assertion as passed
- **`fail_test "message"`** - Mark test assertion as failed
- **`info_log "message"`** - Log informational message
- **`kubectl_retry <command>`** - Run kubectl command with retry logic

**Example**:
```bash
if kubectl_retry kubectl get namespace test-ns >/dev/null 2>&1; then
    pass_test "Namespace test-ns exists"
else
    fail_test "Namespace test-ns not found"
fi
```

## Environment Variables

Available variables (set by `run-tests-full-isolation.sh`):

- **`$NAMESPACE`** - Kubernetes namespace (default: `permissions-binder-operator`)
- **`$TEST_RESULTS`** - Path to test results log file
- **`$SCRIPT_DIR`** - Directory where test scripts are located
- **`$KUBECONFIG`** - Path to kubeconfig file

## Best Practices

1. **Idempotent Tests**: Tests should be idempotent - running multiple times should produce same results
2. **Self-Contained**: Each test should set up its own resources and clean up after itself
3. **Clear Assertions**: Use `pass_test()` and `fail_test()` for clear pass/fail criteria
4. **Informative Logs**: Use `info_log()` to explain what the test is doing
5. **Error Handling**: Use `kubectl_retry()` for kubectl commands that might fail transiently
6. **Wait for Reconciliation**: Add appropriate `sleep` delays for operator to process changes

## Test Categories

When adding a test, assign it to the appropriate category:

- **Basic Functionality (1-11)**: Core operator features
- **Security & Reliability (12-24)**: Security validation, error handling
- **Metrics & Monitoring (25-30)**: Prometheus metrics
- **ServiceAccount Management (31-41)**: ServiceAccount features
- **Bug Fixes (42-43)**: Regression tests for fixed bugs
- **NetworkPolicy Management (44-48)**: NetworkPolicy GitOps features

## Example: Adding Test 49

1. Create `scenarios/49-new-feature.md`:
```markdown
### Test 49: New Feature Test

**Objective**: Verify new feature works correctly

**Setup**:
```bash
# Setup commands
```

**Execution**:
```bash
# Test commands
```

**Expected Result**:
- ✅ Feature works as expected
```

2. Create `test-implementations/test-49-new-feature.sh`:
```bash
#!/bin/bash
# Test 49: New Feature Test
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

echo "Test 49: New Feature Test"
echo "-------------------------"

# Test implementation
pass_test "New feature works correctly"

echo ""
```

3. Add to `run-tests-full-isolation.sh`:
```bash
TEST_FILES=(
    # ... existing tests ...
    "test-49-new-feature.sh"
)
```

4. Update documentation:
   - Add to `e2e-test-scenarios.md`
   - Add to `scenarios/README.md`

5. Test it:
```bash
./run-tests-full-isolation.sh 49
```

## Troubleshooting

### Test Not Found
- Check filename matches pattern: `test-XX-*.sh`
- Verify test is in `TEST_FILES` array in `run-tests-full-isolation.sh`

### Test Fails Immediately
- Check if `test-common.sh` is sourced correctly
- Verify `$NAMESPACE` and other variables are set
- Check test file has execute permissions: `chmod +x test-XX-*.sh`

### Test Can't Find Resources
- Remember: Each test runs with **full isolation** (fresh cluster)
- Test must create its own resources
- Use appropriate wait times for reconciliation

## Checklist

Before submitting a new test:

- [ ] Scenario file created in `scenarios/`
- [ ] Implementation file created in `test-implementations/`
- [ ] Test added to `TEST_FILES` in `run-tests-full-isolation.sh`
- [ ] Documentation updated (`e2e-test-scenarios.md`, `scenarios/README.md`)
- [ ] Test runs successfully: `./run-tests-full-isolation.sh XX`
- [ ] Test is idempotent (can run multiple times)
- [ ] Test cleans up after itself (if needed)
- [ ] Test uses helper functions (`pass_test`, `fail_test`, `info_log`)
- [ ] Test file has execute permissions

