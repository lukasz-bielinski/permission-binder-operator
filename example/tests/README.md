# E2E Test Suite

## Overview

Comprehensive End-to-End test suite for the Permission Binder Operator covering all scenarios from `e2e-test-scenarios.md`.

**All tests are run with FULL ISOLATION** - each test gets a fresh cluster cleanup and fresh operator deployment. The PermissionBinder CRD is cluster-scoped and shared by all tests, so it is installed **once** at suite start and left in place by per-test cleanup.

## Test Structure

- **`run-tests-full-isolation.sh`** - Main test runner (FULL ISOLATION mode)
- **`test-common.sh`** - Common helper functions used by all tests
- **`test-implementations/`** - Individual test implementation files (1 test = 1 file)
- **`scenarios/`** - Test scenario documentation (1 scenario = 1 file)
- **`cleanup-operator.sh`** - Cluster cleanup script (keeps the CRD by default; use `--full` for a complete wipe)

## Running Tests

### Full Isolation Mode (Always Used)

The runner installs the PermissionBinder CRD (`deployment/crd.yaml`) **once** at suite start. Each test then gets:
1. **Fresh cluster cleanup** - All operator resources removed (the CRD is kept)
2. **Fresh operator deployment** - New operator pod deployed from scratch (namespace/RBAC/Deployment only, no CRD re-apply)
3. **Test execution** - Test runs against clean environment

> **Manual full reset:** `./cleanup-operator.sh --full` also deletes the CRD (the runner re-installs it on the next suite start).

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

### Runner environment variables

All optional; read by `run-tests-full-isolation.sh` and inherited by every slot and by Pool C when launched through `run-tests-parallel.sh`.

| Variable | Default | Effect |
|---|---|---|
| `KUBECONFIG` | `$HOME/.kube/config` | Kubeconfig for every `kubectl` call. Both runners and a standalone `cleanup-operator.sh` exit with `ERROR: kubeconfig not readable: <path>` when the (first, if colon-separated) file is unreadable, then run a preflight `kubectl get --raw /readyz --request-timeout=10s` (`cleanup-operator.sh` probes 3 times, 5 s apart) and exit **before any cleanup** when the API server does not answer. The resolved path and `kubectl config current-context` are printed by every script before it touches the cluster. |
| `OPERATOR_IMAGE` | tag committed in `deployment/operator-deployment.yaml` | Run the suite against another image (`repo:tag` or `repo@sha256:...`). The override is rendered into a per-run copy `$RUN_DIR/operator-deployment[-INSTANCE]-image.yaml` in both legacy and `INSTANCE` modes; the committed manifest is never modified. The runner logs `Operator image override: ...`, prints the live Deployment image (`Image: ...`, read with up to 3 attempts) after every deploy, and aborts the run if a readable image differs from the override (an unreadable one only fails that test). Allowed characters: `A-Za-z0-9._/:@-`; `run-tests-parallel.sh` validates this once up front. |
| `OPERATOR_IMAGE_PULL_POLICY` | `Always` when `OPERATOR_IMAGE` is set | `imagePullPolicy` for the override (`Always`, `IfNotPresent` or `Never`), so moving tags such as `sha-<7>` or `latest` are re-pulled on every deploy. Ignored without `OPERATOR_IMAGE` (the manifest value is kept). |
| `GITHUB_GITOPS_SECRET_FILE` | `<repo>/temp/github-gitops-credentials-secret.yaml` | Secret manifest with the GitHub GitOps credentials for the NetworkPolicy tests (see [GitHub Credentials](#github-credentials-secrets)). Honoured by the runner, by `get_np_token`/`np_gh` in `test-common.sh` and by every NetworkPolicy test. An explicit path that is unreadable is a hard error. |
| `GITHUB_GITOPS_READONLY_SECRET_FILE` | `<repo>/temp/github-gitops-credentials-readonly-secret.yaml` | Read-only credentials manifest used by test 57. |
| `E2E_WAIT_MULT` | `1` (`1.5` under `run-tests-parallel.sh --slots > 1`) | Multiplies harness-owned sleeps and timeouts. |
| `INSTANCE` | unset (legacy mode) | Set per slot by `run-tests-parallel.sh`: derives `NAMESPACE=pbo-e2e-N`, `TEST_NS_PREFIX=pboN-`, `RUN_DIR=/tmp/pbo-e2e-N` and suffixes the cluster-scoped RBAC/ServiceMonitor names with `-N`. |
| `E2E_ALLOW_LEGACY` | `0` | `=1` lets an `INSTANCE` run proceed although a legacy (cluster-wide) operator is running. |

```bash
# Release gate: validate a main build without touching the committed manifest
OPERATOR_IMAGE=lukaszbielinski/permission-binder-operator:sha-8554dbc ./run-tests-parallel.sh

# Credentials kept outside the repo
GITHUB_GITOPS_SECRET_FILE=/secure/github-gitops-credentials-secret.yaml ./run-tests-parallel.sh 44 45 48
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
- The runner, `test-common.sh` (`get_np_token`) and the NetworkPolicy tests apply these manifests by:
  - Resolving the path as `${GITHUB_GITOPS_SECRET_FILE:-temp/github-gitops-credentials-secret.yaml}` (test 57: `${GITHUB_GITOPS_READONLY_SECRET_FILE:-temp/github-gitops-credentials-readonly-secret.yaml}`), and
  - Rewriting `namespace: permissions-binder-operator` to the instance namespace at runtime.
- File contract: a `Secret` named `github-gitops-credentials` in `namespace: permissions-binder-operator` whose `stringData` holds `token: "<PAT>"` — the token value **must be double-quoted**, because `get_np_token` extracts it with an `awk` split on `"`.
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
- Deletes the operator's ServiceMonitor from the `monitoring` namespace (`permission-binder-operator-metrics[-INSTANCE]`; skipped when the ServiceMonitor CRD is not installed; a real delete error is printed, not masked)
- Refuses to run (exit 1, before any delete) when `KUBECONFIG` is unreadable or the API server does not answer `/readyz` (3 probes, 5 s apart); prints the kubeconfig path and context first
- The runner retries a failed cleanup once and marks the test **FAIL** (skipping deploy) if it still exits non-zero, so a test never runs on top of the previous test's state
- `run-tests-parallel.sh` runs it once more after Pool C, so a full parallel run leaves no operator or ServiceMonitor behind

### Step 2: Fresh Operator Deployment
```bash
kubectl apply -f deployment/operator-deployment.yaml -f deployment/servicemonitor.yaml
```
- Deploys operator from scratch (the CRD from `deployment/crd.yaml` is already installed and is not re-applied)
- With `OPERATOR_IMAGE` set, the manifest applied is the per-run copy `$RUN_DIR/operator-deployment[-INSTANCE]-image.yaml` carrying the override; the live Deployment image is logged and checked
- Creates GitHub GitOps credentials Secret (if the file exists; path from `GITHUB_GITOPS_SECRET_FILE`)
- Waits for operator pod to be ready (timeout: 120s)

### Step 3: Test Execution
- Runs individual test from `test-implementations/` directory
- Test uses common functions from `test-common.sh`
- Results logged to individual test log file

### Test namespace sweep (legacy mode)

Step 1 deletes the test namespaces of the run it belongs to. With `INSTANCE`
set (parallel slots) that is every namespace starting with `TEST_NS_PREFIX`
(`pboN-`). In **legacy mode** (no `INSTANCE`: `./run-tests-full-isolation.sh`,
explicit lists such as `./run-tests-parallel.sh 04 17`, the pre-parallel sweep
and the Pool C serial phase) `cleanup-operator.sh` deletes the union of

- namespaces labelled `permission-binder.io/managed-by=<MANAGED_BY_VALUE>`
  (default `permission-binder-operator`), i.e. everything the e2e operator
  created or adopted from whitelist entries, and
- an **anchored allow-list** (`TEST_NS_ALLOWLIST` in `cleanup-operator.sh`) of
  every namespace name the test bodies create themselves,

minus **protected namespaces** (`kube-*`, `default`, `monitoring`, `argocd*`,
`metallb-system`, `cattle-*`, `openshift-*`, `permission-binder-*`, the
operator namespace) and, in legacy mode, the parallel-slot namespaces
(`pbo-e2e-N`, `pboN-*`) that may belong to a run that is still going. A
protected namespace adopted by a test (test 47 whitelists `kube-system`) is
never deleted: its operator marks (`permission-binder.io/*` label and
annotations) and the managed RoleBinding are stripped instead.

The parallel-slot guard means a `pboN-*` namespace that a leftover legacy
operator adopted under the default label (issue #55) is normally reclaimed only
when that slot number runs again. The pre-parallel sweep in
`run-tests-parallel.sh` - the one legacy call where no slot can be running -
sets `SWEEP_SLOT_NAMESPACES=1` to lift the guard and reclaim them there; do not
set it on any other call.

`MANAGED_BY_VALUE` follows `test-common.sh` exactly: default
`permission-binder-operator`, env-overridable in legacy mode, always
`permission-binder-operator-<INSTANCE>` when `INSTANCE` is set.

Dry run - print what the sweep would delete without touching anything:
```bash
./cleanup-operator.sh --list-test-namespaces
# stdout: one namespace per line (empty on an idle cluster)
# stderr: the kubeconfig/context in use; protected / parallel-slot namespaces
#         that were skipped (a protected namespace that carries the managed-by
#         label is reported as "marks stripped, never deleted")
# exit:   non-zero (nothing printed on stdout) when the kubeconfig is
#         unreadable or the API server fails the /readyz probe - an empty list
#         therefore always means "nothing to delete", never "unreachable"
```

The label half deletes whatever an operator running with the default
`MANAGED_BY_VALUE` manages, so run legacy cleanup on **test clusters only**.
Naming rules for new tests: [`ADDING_NEW_TESTS.md`](ADDING_NEW_TESTS.md#test-namespace-naming-cleanup-contract).

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
- Verify Docker image is available: `docker pull lukaszbielinski/permission-binder-operator:1.8.1`
- Check operator pod logs: `kubectl logs -n permissions-binder-operator deployment/operator-controller-manager`

### Test Fails During Execution
- Check `/tmp/test-<test_id>-isolated.log` for test-specific errors
- Verify operator is running: `kubectl get pods -n permissions-binder-operator`
- Check operator logs: `kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=100`

### NetworkPolicy Tests Fail
- Verify GitHub credentials Secret exists: `kubectl get secret github-gitops-credentials -n permissions-binder-operator`
- Check if credentials file exists: `ls -la ../../temp/github-gitops-credentials-secret.yaml` (or the path in `GITHUB_GITOPS_SECRET_FILE`)
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
