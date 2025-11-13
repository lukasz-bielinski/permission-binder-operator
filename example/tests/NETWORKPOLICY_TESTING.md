# NetworkPolicy E2E Testing Guide

## Overview

NetworkPolicy E2E tests verify that the operator correctly creates GitHub Pull Requests with NetworkPolicy files. These tests are **asynchronous** - the operator creates PRs in the background, so tests must wait and verify.

## Test Structure

Each NetworkPolicy test:
1. **Sets up** PermissionBinder with NetworkPolicy enabled
2. **Creates** ConfigMap with test namespaces
3. **Waits** for operator to process and create PR (up to 120s)
4. **Verifies** PR in PermissionBinder status
5. **Verifies** PR on GitHub using `gh` CLI
6. **Verifies** PR content (files, paths, descriptions)

## Prerequisites

### Required Tools

**CRITICAL**: These tools are **required** - tests will fail if missing:

- **`kubectl`** - Kubernetes CLI (required for all tests)
- **`jq`** - JSON processor (required for many tests)
  ```bash
  # Install jq:
  sudo apt-get install jq      # Debian/Ubuntu
  brew install jq              # macOS
  yum install jq               # RHEL/CentOS
  ```
- **`gh` CLI** - GitHub CLI (required for NetworkPolicy tests 44-48)
  ```bash
  # Install gh:
  # https://cli.github.com/manual/installation
  ```
- Access to GitHub repository: `lukasz-bielinski/tests-network-policies`

**Note**: If any required tool is missing, tests will fail immediately with installation instructions.

### GitHub Authentication

**Option 1: gh CLI authentication**
```bash
gh auth login
# Follow prompts to authenticate
```

**Option 2: Use token from Secret**
```bash
# Token is in temp/github-gitops-credentials-secret.yaml
# gh CLI can use GITHUB_TOKEN environment variable
export GITHUB_TOKEN=$(kubectl get secret github-gitops-credentials -n permissions-binder-operator -o jsonpath='{.data.token}' | base64 -d)
```

### Verify Setup
```bash
# Check gh CLI
gh --version
gh auth status

# Check jq
jq --version

# Test GitHub access
gh repo view lukasz-bielinski/tests-network-policies
```

## Test Functions

### Helper Functions (in `test-common.sh`)

#### `wait_for_pr_in_status(namespace, test_namespace, max_wait)`
Waits for PR number to appear in PermissionBinder status.
- **Returns**: PR number if found, empty string otherwise
- **Timeout**: Default 120 seconds

#### `get_pr_from_status(namespace, test_namespace)`
Gets PR details from PermissionBinder status.
- **Returns**: `pr_number|pr_url|pr_branch|pr_state` (pipe-separated)

#### `verify_pr_on_github(repo, pr_number)`
Verifies PR exists on GitHub using `gh` CLI.
- **Returns**: PR JSON if found, empty string otherwise
- **Checks**: gh CLI availability, authentication, PR existence

#### `verify_pr_files(repo, pr_number, expected_files)`
Verifies PR contains expected files.
- **Parameters**: Space-separated list of file paths
- **Returns**: 0 if all files found, 1 otherwise

#### `verify_kustomization_paths(repo, pr_number, kustomization_path)`
Verifies kustomization.yaml contains correct relative paths (no `../../` prefixes).
- **Returns**: 0 if paths are correct, 1 if incorrect paths found

#### `wait_for_pr_state(namespace, test_namespace, expected_state, max_wait)`
Waits for PR state to change (e.g., `pr-pending` -> `pr-merged`).
- **Returns**: 0 if state matches, 1 if timeout

## Test Scenarios

### Test 44: Variant A (New File from Template)

**What it tests:**
- Operator creates PR for new namespace from template
- PR contains NetworkPolicy file
- PR contains updated kustomization.yaml
- PR paths are correct (no `../../` prefixes)

**Verification:**
1. PR number in PermissionBinder status
2. PR exists on GitHub
3. PR contains expected files
4. kustomization.yaml paths are correct
5. PR title contains namespace
6. PR description contains namespace

**Expected Files:**
- `networkpolicies/DEV-cluster/test-app/test-app-deny-all-ingress.yaml`
- `networkpolicies/DEV-cluster/kustomization.yaml`

### Test 45: Variant B (Backup Existing Template-based Policy)

**What it tests:**
- Operator backs up existing NetworkPolicy
- PR contains backup file
- PR indicates backup variant

**Verification:**
1. PR number in PermissionBinder status
2. PR exists on GitHub
3. PR contains backup files
4. PR title indicates backup variant

**Expected Files:**
- `networkpolicies/DEV-cluster/test-backup-ns/test-backup-ns-deny-all-ingress.yaml`
- `networkpolicies/DEV-cluster/kustomization.yaml`

## Running Tests

### Single Test
```bash
cd example/tests
./run-tests-full-isolation.sh 44
```

### Multiple Tests
```bash
./run-tests-full-isolation.sh 44 45 46 47 48
```

### All NetworkPolicy Tests
```bash
./run-tests-full-isolation.sh 44 45 46 47 48
```

## Troubleshooting

### PR Not Found in Status

**Symptoms:**
- Test fails: "PR number not found in PermissionBinder status after 120s"

**Possible Causes:**
1. Operator hasn't processed namespace yet (needs more time)
2. PR creation failed (check operator logs)
3. Status update failed

**Debug:**
```bash
# Check operator logs
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | jq 'select(.message | contains("NetworkPolicy") or contains("PR"))'

# Check PermissionBinder status
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o yaml | grep -A 20 "networkPolicies:"

# Check if namespace is processed
kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[*].namespace}'
```

### PR Not Found on GitHub

**Symptoms:**
- Test fails: "PR not found on GitHub or gh CLI not available"

**Possible Causes:**
1. gh CLI not authenticated
2. PR not yet created (GitHub API delay)
3. Wrong repository

**Debug:**
```bash
# Check gh authentication
gh auth status

# Check PR manually
gh pr list --repo lukasz-bielinski/tests-network-policies

# Check PR by number (from status)
PR_NUMBER=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-app")].prNumber}')
gh pr view $PR_NUMBER --repo lukasz-bielinski/tests-network-policies
```

### Incorrect kustomization.yaml Paths

**Symptoms:**
- Test fails: "kustomization.yaml contains incorrect paths with ../../ prefix"

**Possible Causes:**
1. Bug in operator code (double-relativization)
2. Incorrect path calculation

**Debug:**
```bash
# Get PR number
PR_NUMBER=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-app")].prNumber}')

# View kustomization.yaml diff
gh pr diff $PR_NUMBER --repo lukasz-bielinski/tests-network-policies networkpolicies/DEV-cluster/kustomization.yaml

# Check for ../../ prefixes
gh pr diff $PR_NUMBER --repo lukasz-bielinski/tests-network-policies networkpolicies/DEV-cluster/kustomization.yaml | grep -E "^\+\s*\.\./\.\./"
```

### Missing Files in PR

**Symptoms:**
- Test fails: "Could not verify all PR files"

**Possible Causes:**
1. PR not fully processed by GitHub (needs more time)
2. Files not created by operator
3. Wrong file paths

**Debug:**
```bash
# List all files in PR
PR_NUMBER=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n permissions-binder-operator -o jsonpath='{.status.networkPolicies[?(@.namespace=="test-app")].prNumber}')
gh pr view $PR_NUMBER --repo lukasz-bielinski/tests-network-policies --json files --jq '.files[].path'

# Check PR diff
gh pr diff $PR_NUMBER --repo lukasz-bielinski/tests-network-policies
```

## Test Timing

### Asynchronous Operations

NetworkPolicy tests must account for:
1. **Operator processing time**: 5-30 seconds
2. **Git operations**: 5-10 seconds
3. **GitHub API delay**: 2-5 seconds
4. **Status update**: 1-2 seconds

**Total wait time**: Up to 120 seconds per test

### Wait Strategies

1. **Status-based waiting**: Wait for PR number in PermissionBinder status
2. **Polling**: Check every 5 seconds
3. **Timeout**: Fail after 120 seconds

## Best Practices

1. **Always verify PR on GitHub**: Don't rely only on PermissionBinder status
2. **Check file content**: Verify actual files in PR, not just existence
3. **Verify paths**: Check kustomization.yaml paths are correct
4. **Handle timeouts gracefully**: Provide helpful error messages
5. **Log PR details**: Include PR number, URL, branch in logs

## Example Test Output

```
Test 44: NetworkPolicy - Variant A (New File from Template)
------------------------------------------------------------
ℹ️  Creating GitHub GitOps credentials Secret from ...
ℹ️  Creating PermissionBinder with NetworkPolicy enabled
ℹ️  Waiting for PermissionBinder to process ConfigMap (10s)
✅ PASS: NetworkPolicy status entries found: test-app test-app-2
ℹ️  Waiting for PR to be created (up to 120s)...
✅ PASS: PR number found in status: 42
ℹ️  PR Details from status:
ℹ️    Number: 42
ℹ️    URL: https://github.com/lukasz-bielinski/tests-network-policies/pull/42
ℹ️    Branch: networkpolicy-test-app-20250113
ℹ️    State: pr-pending
ℹ️  Verifying PR on GitHub...
✅ PASS: PR 42 exists on GitHub
ℹ️  GitHub PR Details:
ℹ️    Title: NetworkPolicy: new for namespace test-app
ℹ️    State: OPEN
ℹ️    Branch: networkpolicy-test-app-20250113
ℹ️    URL: https://github.com/lukasz-bielinski/tests-network-policies/pull/42
✅ PASS: PR title contains namespace: test-app
ℹ️  Verifying PR files...
✅ PASS: PR contains expected NetworkPolicy files
ℹ️  Verifying kustomization.yaml paths...
✅ PASS: kustomization.yaml contains correct relative paths (no ../../ prefixes)
✅ PASS: PR description contains namespace: test-app
✅ PASS: test-app namespace has valid PR state: pr-pending
```

## Related Documentation

- [E2E Test Scenarios](e2e-test-scenarios.md)
- [Adding New Tests](ADDING_NEW_TESTS.md)
- [Test Coverage Checklist](TEST_COVERAGE_CHECKLIST.md)

