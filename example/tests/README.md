# E2E Test Suite

## Overview

Comprehensive End-to-End test suite for the Permission Binder Operator covering all scenarios from `e2e-test-scenarios.md`.

**All tests are run with FULL ISOLATION** - each test gets a fresh cluster cleanup and fresh operator deployment.

## Test Structure

- **`run-tests-full-isolation.sh`** - Main test runner (FULL ISOLATION mode)
- **`test-common.sh`** - Common helper functions used by all tests
- **`test-implementations/`** - Individual test implementation files (1 test = 1 file)
- **`scenarios/`** - Test scenario documentation (1 scenario = 1 file)
- **`cleanup-operator.sh`** - Cluster cleanup script

## Running Tests

### Full Isolation Mode (Always Used)

All tests are run with full isolation - each test gets:
1. **Fresh cluster cleanup** - All operator resources removed
2. **Fresh operator deployment** - New operator pod deployed from scratch
3. **Test execution** - Test runs against clean environment

```bash
# Run all tests (Pre-Test + Tests 1-48)
./run-tests-full-isolation.sh

# Run single test
./run-tests-full-isolation.sh 44

# Run specific tests
./run-tests-full-isolation.sh 44 45 46 47 48

# Run pre-test only
./run-tests-full-isolation.sh pre
```

### Test IDs

- `pre` or `00` - Pre-Test: Initial State Verification
- `1-48` - Individual test numbers

## Test Documentation

- **Main Documentation**: `e2e-test-scenarios.md` - Overview and quick reference
- **Individual Scenarios**: `scenarios/` - One file per test scenario
- **Adding New Tests**: `ADDING_NEW_TESTS.md` - Step-by-step guide
- **Test Coverage**: `TEST_COVERAGE_CHECKLIST.md` - Coverage checklist and gaps
- **Test Template**: `test-template.sh` - Template for new tests
- **NetworkPolicy Testing**: `NETWORKPOLICY_TESTING.md` - Guide for NetworkPolicy E2E tests with GitHub PR verification

## Test Results

Results are saved to:
- **Main log**: `/tmp/e2e-full-isolation-YYYYMMDD-HHMMSS.log`
- **Individual test logs**: `/tmp/test-<test_id>-isolated.log`
- **Cleanup logs**: `/tmp/cleanup-<test_id>.log`
- **Deploy logs**: `/tmp/deploy-<test_id>.log`

## Prerequisites

### Required Tools
- **kubectl** - Kubernetes CLI (required for all tests)
- **jq** - JSON processor (required for many tests)
  ```bash
  # Install jq:
  sudo apt-get install jq      # Debian/Ubuntu
  brew install jq              # macOS
  yum install jq               # RHEL/CentOS
  ```
- **gh** - GitHub CLI (required for NetworkPolicy tests 44-48)
  ```bash
  # Install gh:
  # https://cli.github.com/manual/installation
  gh auth login  # Authenticate after installation
  ```

### Cluster Requirements
- K3s cluster with mixed architectures (ARM64 and AMD64)
- Operator Docker image available (see `example/deployment/operator-deployment.yaml`)
- GitHub credentials for NetworkPolicy tests (see `temp/github-gitops-credentials-secret.yaml`)

### GitHub Credentials (Secrets)

- **Never commit tokens** – secrets live only in `temp/` (gitignored).
- Default templates:
  - `temp/github-gitops-credentials-secret.yaml` (read/write access)
  - `temp/github-gitops-credentials-readonly-secret.yaml` (read-only scenario tests)
- Tests automatically apply these manifests by:
  - Replacing the namespace at runtime, and
  - Using the `GITHUB_GITOPS_SECRET_FILE` env var to override the default path if needed.
- Before running tests:
  1. Populate the YAML files with fresh tokens.
  2. Keep the files local (they remain untracked).
  3. Rotate tokens immediately if they were ever committed.

## How Full Isolation Works

### Step 1: Cluster Cleanup
```bash
./cleanup-operator.sh
```
- Deletes all PermissionBinders
- Deletes all ConfigMaps
- Deletes all operator-managed RoleBindings
- Deletes all operator-managed Namespaces
- Deletes operator deployment and related resources
- Deletes GitHub GitOps credentials Secret (if exists)

### Step 2: Fresh Operator Deployment
```bash
kubectl apply -f deployment/
```
- Deploys operator from scratch
- Creates GitHub GitOps credentials Secret (if file exists)
- Waits for operator pod to be ready (timeout: 120s)

### Step 3: Test Execution
- Runs individual test from `test-implementations/` directory
- Test uses common functions from `test-common.sh`
- Results logged to individual test log file

## Test Categories

- **Basic Functionality (Tests 1-11)**: Core operator features, role mapping, prefixes, ConfigMap handling
- **Security & Reliability (Tests 12-24)**: Security validation, error handling, observability
- **Metrics & Monitoring (Tests 25-30)**: Prometheus metrics, metrics updates
- **ServiceAccount Management (Tests 31-41)**: ServiceAccount creation, protection, updates
- **Bug Fixes (Tests 42-43)**: RoleBindings with hyphenated roles, invalid whitelist entry handling
- **NetworkPolicy Management (Tests 44-48)**: GitOps-based NetworkPolicy management, PR creation, drift detection

## Troubleshooting

### Test Fails During Cleanup
- Check `/tmp/cleanup-<test_id>.log` for errors
- Verify cluster is accessible: `kubectl cluster-info`
- Check if resources are stuck in Terminating state

### Test Fails During Deployment
- Check `/tmp/deploy-<test_id>.log` for errors
- Verify Docker image is available: `docker pull lukaszbielinski/permission-binder-operator:1.6.0-rc2`
- Check operator pod logs: `kubectl logs -n permissions-binder-operator deployment/operator-controller-manager`

### Test Fails During Execution
- Check `/tmp/test-<test_id>-isolated.log` for test-specific errors
- Verify operator is running: `kubectl get pods -n permissions-binder-operator`
- Check operator logs: `kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=100`

### NetworkPolicy Tests Fail
- Verify GitHub credentials Secret exists: `kubectl get secret github-gitops-credentials -n permissions-binder-operator`
- Check if credentials file exists: `ls -la ../../temp/github-gitops-credentials-secret.yaml`
- Verify GitHub repository is accessible: `curl -H "Authorization: token <TOKEN>" https://api.github.com/repos/lukasz-bielinski/tests-network-policies`

## Example Output

```
╔═══════════════════════════════════════════════════════════════╗
║     🧪 E2E Tests with FULL ISOLATION                          ║
╚═══════════════════════════════════════════════════════════════╝

[1/49] Test pre: Pre-Test: Initial State Verification
═════════════════════════════════════════════════════════════════
🧹 Step 1/3: Cleaning cluster...
   ✅ Cluster cleaned
📦 Step 2/3: Deploying fresh operator...
   ✅ Operator ready
      Pod: operator-controller-manager-xxxxx
      Started: 2025-01-13T10:00:00Z
▶️  Step 3/3: Running test pre...
   ✅ Test pre PASSED

Progress: 1/49 (✅ 1 passed, ❌ 0 failed)
```

## Success Criteria

All tests should pass without errors. The test suite verifies:
- ✅ Functional requirements (all features work correctly)
- ✅ Production-grade requirements (logging, metrics, reliability)
- ✅ Security requirements (RBAC validation, no privilege escalation)
- ✅ Compliance requirements (audit trail, structured logging)
