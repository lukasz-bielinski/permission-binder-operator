# Unit Test Coverage Analysis
**Date**: 2025-11-13  
**Branch**: `testing/improve-unit-coverage`  
**Current Coverage**: **12.2%** (Target: 80%)

---

## 📊 **Current State**

### Coverage by Package

| Package | Coverage | Status |
|---------|----------|--------|
| `api/v1` | **0.0%** | ❌ No tests |
| `cmd` | **0.0%** | ❌ No tests |
| `cmd/git-askpass-helper` | **0.0%** | ❌ No tests |
| `internal/controller` | **13.3%** | ⚠️ Low coverage |
| `internal/controller/networkpolicy` | **14.8%** | ⚠️ Low coverage |
| `test/e2e` | N/A | Integration tests only |
| `test/utils` | **0.0%** | ❌ No tests |

**Total**: **12.2%** coverage

---

## 🔍 **Files Without Tests (NetworkPolicy Package)**

### High Priority (Large, Complex Files)

| File | Lines | Complexity | Priority | Reason |
|------|-------|------------|----------|--------|
| `git_api.go` | 422 | High | **CRITICAL** | GitHub API operations, error handling |
| `reconciliation_single.go` | 404 | High | **CRITICAL** | Core reconciliation logic |
| `network_policy_status.go` | 308 | Medium | **HIGH** | Status management, race conditions |
| `git_cli.go` | 282 | High | **CRITICAL** | Git operations, security-critical |
| `network_policy_drift.go` | 274 | Medium | **HIGH** | Drift detection logic |
| `network_policy_template_simple.go` | 191 | Medium | **HIGH** | Template processing, YAML manipulation |
| `reconciliation_cleanup.go` | 178 | Medium | **MEDIUM** | Cleanup logic |
| `network_policy_kustomization_simple.go` | 157 | Medium | **MEDIUM** | Kustomization file generation |
| `reconciliation_periodic.go` | 153 | Medium | **MEDIUM** | Periodic reconciliation |
| `reconciliation_batch.go` | 129 | Medium | **MEDIUM** | Batch processing |

### Lower Priority (Smaller Files)

| File | Lines | Complexity | Priority | Reason |
|------|-------|------------|----------|--------|
| `network_policy_constants.go` | 138 | Low | **LOW** | Constants (usually don't need tests) |
| `reconciliation_validation.go` | 81 | Low | **MEDIUM** | Validation logic |
| `network_policy_backup_simple.go` | 81 | Low | **MEDIUM** | Backup logic |
| `git_file_operations.go` | 66 | Low | **MEDIUM** | File I/O wrappers |
| `git_credentials.go` | 61 | Low | **MEDIUM** | Credentials handling |
| `reconciler_interface.go` | 45 | Low | **LOW** | Interface definition |
| `git_operations.go` | 32 | Low | **LOW** | Wrapper/orchestrator |
| `network_policy_reconciliation.go` | 28 | Low | **LOW** | Entry point |

---

## 🎯 **Testing Strategy**

### Phase 1: Critical Security & Core Logic (Target: 40% coverage)

#### 1.1 Git CLI Operations (`git_cli.go` - 282 lines) **CRITICAL**
- **Why**: Security-critical (credential handling), complex error scenarios
- **Tests Needed**:
  - `TestCloneGitRepo_Success` - Happy path
  - `TestCloneGitRepo_InvalidURL` - Error handling
  - `TestCloneGitRepo_AuthFailure` - Credential errors
  - `TestGitCheckoutBranch_NewBranch` - Branch creation
  - `TestGitCheckoutBranch_ExistingBranch` - Branch switching
  - `TestGitCommitAndPush_Success` - Normal push
  - `TestGitCommitAndPush_NoChanges` - Empty diff
  - `TestGitCommitAndPush_Rebase` - Rebase scenario
  - `TestGitCommitAndPush_ForceRequired` - Force push scenario
  - `TestGetAskPassHelperPath` - Helper path resolution
  - `TestWithGitCredentials` - Environment setup
- **Mocking**: Git commands via `exec.Command` (use testable wrappers)
- **Estimated LOC**: ~400 lines

#### 1.2 GitHub API Operations (`git_api.go` - 422 lines) **CRITICAL**
- **Why**: Complex API interactions, error handling, rate limiting
- **Tests Needed**:
  - `TestGitAPIRequest_Success` - HTTP request/response
  - `TestGitAPIRequest_RateLimit` - 403 handling
  - `TestGitAPIRequest_NotFound` - 404 handling
  - `TestCreatePullRequest_Success` - PR creation
  - `TestCreatePullRequest_AlreadyExists` - Duplicate PR
  - `TestGetPRByBranch_Found` - PR lookup
  - `TestGetPRByBranch_NotFound` - No PR
  - `TestMergePullRequest_Success` - Auto-merge
  - `TestMergePullRequest_ConflictDetection` - Merge conflicts
  - `TestDeleteBranch_Success` - Branch deletion
  - `TestDeleteBranch_NotFound` - Already deleted
- **Mocking**: HTTP client (use `httptest.Server`)
- **Estimated LOC**: ~500 lines

#### 1.3 Core Reconciliation (`reconciliation_single.go` - 404 lines) **CRITICAL**
- **Why**: Core business logic, complex state management
- **Tests Needed**:
  - `TestProcessNetworkPolicyForNamespace_VariantA` - New from template
  - `TestProcessNetworkPolicyForNamespace_VariantB` - Backup existing
  - `TestProcessNetworkPolicyForNamespace_VariantC` - Backup non-template
  - `TestProcessNetworkPolicyForNamespace_NoChanges` - Idempotency
  - `TestProcessNetworkPolicyForNamespace_MultiplePolicies` - Multiple files
  - `TestProcessNetworkPolicyForNamespace_ExcludedNamespace` - Exclusion logic
  - `TestProcessNetworkPolicyForNamespace_CleanupBranch` - Branch cleanup
- **Mocking**: K8s client, Git operations
- **Estimated LOC**: ~600 lines

---

### Phase 2: Status & State Management (Target: 60% coverage)

#### 2.1 Status Management (`network_policy_status.go` - 308 lines)
- **Why**: Race conditions, concurrent updates
- **Tests Needed**:
  - `TestUpdateNetworkPolicyStatusWithPR_Success` - Status update
  - `TestUpdateNetworkPolicyStatusWithPR_RetryOnConflict` - Retry logic
  - `TestUpdateNetworkPolicyStatusWithPR_MaxRetriesExceeded` - Failure after retries
  - `TestCleanupStatus_RemoveOldEntries` - Retention logic
  - `TestCleanupStatus_PreserveActiveEntries` - Active namespace handling
  - `TestCleanupStatus_RaceCondition` - Concurrent update simulation
- **Mocking**: K8s client with controlled conflicts
- **Estimated LOC**: ~350 lines

#### 2.2 Drift Detection (`network_policy_drift.go` - 274 lines)
- **Why**: Complex comparison logic
- **Tests Needed**:
  - `TestDetectDrift_NoChanges` - Identical policies
  - `TestDetectDrift_SpecChanged` - Policy spec differences
  - `TestDetectDrift_LabelsChanged` - Label differences
  - `TestDetectDrift_PolicyAdded` - New policy in cluster
  - `TestDetectDrift_PolicyRemoved` - Policy deleted from cluster
  - `TestDetectDrift_IgnoreAnnotations` - Annotation filtering
- **Mocking**: K8s client
- **Estimated LOC**: ~300 lines

---

### Phase 3: Template & File Operations (Target: 75% coverage)

#### 3.1 Template Processing (`network_policy_template_simple.go` - 191 lines)
- **Why**: YAML manipulation, data transformation
- **Tests Needed**:
  - `TestProcessTemplate_Success` - Template rendering
  - `TestProcessTemplate_InvalidYAML` - Malformed template
  - `TestProcessTemplate_VariableSubstitution` - Variable replacement
  - `TestCleanJSONForGitOps` - Field filtering (kubectl-neat style)
  - `TestCleanJSONForGitOps_PreserveImportantFields` - Keep required fields
- **Mocking**: None (pure functions)
- **Estimated LOC**: ~250 lines

#### 3.2 Kustomization (`network_policy_kustomization_simple.go` - 157 lines)
- **Why**: File generation, path handling
- **Tests Needed**:
  - `TestGenerateKustomization_EmptyDirectory` - Empty input
  - `TestGenerateKustomization_SingleFile` - One policy
  - `TestGenerateKustomization_MultipleFiles` - Multiple policies
  - `TestGenerateKustomization_ExistingKustomization` - Update existing
  - `TestGenerateKustomization_PathNormalization` - Relative paths
- **Mocking**: Filesystem operations
- **Estimated LOC**: ~200 lines

#### 3.3 Backup Logic (`network_policy_backup_simple.go` - 81 lines)
- **Why**: Data integrity, YAML formatting
- **Tests Needed**:
  - `TestBackupNetworkPolicy_Success` - Policy backup
  - `TestBackupNetworkPolicy_CleanYAML` - Clean output
  - `TestBackupNetworkPolicy_PreserveMetadata` - Metadata handling
- **Mocking**: None (pure functions)
- **Estimated LOC**: ~100 lines

---

### Phase 4: Reconciliation Components (Target: 80% coverage)

#### 4.1 Batch Processing (`reconciliation_batch.go` - 129 lines)
- **Why**: Error aggregation, parallel processing
- **Tests Needed**:
  - `TestProcessNetworkPoliciesForNamespaces_AllSuccess` - Happy path
  - `TestProcessNetworkPoliciesForNamespaces_PartialFailure` - Error handling
  - `TestProcessNetworkPoliciesForNamespaces_EmptyInput` - No namespaces
- **Mocking**: K8s client, Git operations
- **Estimated LOC**: ~150 lines

#### 4.2 Periodic Reconciliation (`reconciliation_periodic.go` - 153 lines)
- **Why**: Trigger logic, timing
- **Tests Needed**:
  - `TestPeriodicReconciliation_Trigger` - Reconciliation trigger
  - `TestPeriodicReconciliation_Interval` - Interval calculation
  - `TestPeriodicReconciliation_ErrorHandling` - Error scenarios
- **Mocking**: Time-based operations
- **Estimated LOC**: ~150 lines

#### 4.3 Cleanup Logic (`reconciliation_cleanup.go` - 178 lines)
- **Why**: Resource lifecycle, error handling
- **Tests Needed**:
  - `TestCleanupOrphanedResources_Success` - Cleanup execution
  - `TestCleanupOrphanedResources_PreserveActive` - Active resource handling
  - `TestCleanupOrphanedResources_RetentionPeriod` - Time-based retention
- **Mocking**: K8s client, time
- **Estimated LOC**: ~200 lines

---

## 📝 **Test File Structure (Best Practices)**

### Standard Test File Template

```go
package networkpolicy

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// TestGroup_Function_Scenario follows Go testing conventions
func TestFunctionName_HappyPath(t *testing.T) {
	// Arrange
	ctx := context.Background()
	fakeClient := fake.NewClientBuilder().Build()
	
	// Act
	result, err := functionUnderTest(ctx, fakeClient, testData)
	
	// Assert
	require.NoError(t, err)
	assert.Equal(t, expected, result)
}

// Table-driven tests for multiple scenarios
func TestFunctionName_MultipleScenarios(t *testing.T) {
	tests := []struct {
		name    string
		input   InputType
		want    OutputType
		wantErr bool
	}{
		{
			name:    "success case",
			input:   validInput,
			want:    expectedOutput,
			wantErr: false,
		},
		{
			name:    "error case",
			input:   invalidInput,
			want:    nil,
			wantErr: true,
		},
	}
	
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := functionUnderTest(tt.input)
			if tt.wantErr {
				assert.Error(t, err)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tt.want, got)
		})
	}
}
```

---

## 🛠️ **Mocking Strategies**

### 1. Kubernetes Client
```go
// Use controller-runtime fake client
fakeClient := fake.NewClientBuilder().
	WithObjects(existingObjects...).
	WithStatusSubresource(&v1.PermissionBinder{}).
	Build()
```

### 2. HTTP Client (GitHub API)
```go
// Use httptest for API testing
server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(mockResponse)
}))
defer server.Close()
```

### 3. Exec Commands (Git CLI)
```go
// Create wrapper interface for testing
type CommandExecutor interface {
	ExecContext(ctx context.Context, name string, args ...string) ([]byte, error)
}

// Mock implementation
type MockExecutor struct {
	Responses map[string][]byte
	Errors    map[string]error
}
```

### 4. Filesystem Operations
```go
// Use afero for filesystem mocking
fs := afero.NewMemMapFs()
// or
fs := afero.NewOsFs() // for integration tests
```

---

## 📈 **Coverage Goals by Phase**

| Phase | Focus Area | Target Coverage | Estimated LOC | Priority |
|-------|-----------|-----------------|---------------|----------|
| **1** | Critical & Core | **40%** | ~1,500 lines | ⚠️ **CRITICAL** |
| **2** | Status & State | **60%** | ~650 lines | 🔴 **HIGH** |
| **3** | Template & Files | **75%** | ~550 lines | 🟡 **MEDIUM** |
| **4** | Reconciliation | **80%** | ~500 lines | 🟢 **LOW** |

**Total Estimated**: ~3,200 lines of test code

---

## 🚀 **Implementation Plan**

### Week 1: Critical Security Tests
- [ ] `git_cli_test.go` - Git operations (400 lines)
- [ ] `git_api_test.go` - GitHub API (500 lines)
- **Target**: 25% coverage

### Week 2: Core Reconciliation
- [ ] `reconciliation_single_test.go` - Core logic (600 lines)
- **Target**: 40% coverage

### Week 3: Status & Drift
- [ ] `network_policy_status_test.go` - Status management (350 lines)
- [ ] `network_policy_drift_test.go` - Drift detection (300 lines)
- **Target**: 60% coverage

### Week 4: Templates & Components
- [ ] `network_policy_template_simple_test.go` - Templates (250 lines)
- [ ] `network_policy_kustomization_simple_test.go` - Kustomization (200 lines)
- [ ] `reconciliation_batch_test.go` - Batch processing (150 lines)
- [ ] `reconciliation_periodic_test.go` - Periodic (150 lines)
- [ ] `reconciliation_cleanup_test.go` - Cleanup (200 lines)
- **Target**: 80% coverage

---

## ✅ **Checklist for Each Test File**

- [ ] Table-driven tests for multiple scenarios
- [ ] Happy path tested
- [ ] Error paths tested
- [ ] Edge cases covered (nil, empty, invalid input)
- [ ] Concurrent access tested (where applicable)
- [ ] Mocks properly configured
- [ ] Test names descriptive (TestFunction_Scenario)
- [ ] Assertions clear and meaningful
- [ ] Cleanup in defer blocks
- [ ] No flaky tests (deterministic)

---

## 📊 **Current Test Files (Existing)**

### Already Tested ✅
- `business_logic_test.go` - Permission parsing logic
- `dn_parser_test.go` - LDAP DN parsing
- `helpers_test.go` - Helper functions
- `ldap_helper_test.go` - LDAP operations
- `permission_parser_test.go` - Permission parsing
- `permissionbinder_controller_test.go` - Controller basics
- `service_account_helper_test.go` - ServiceAccount logic
- `status_update_test.go` - Status updates
- `network_policy_business_logic_test.go` - Business logic
- `network_policy_helper_test.go` - Helpers
- `network_policy_utils_test.go` - Utilities

**These provide the 12.2% current coverage!**

---

## 🎯 **Success Criteria**

### Minimum Acceptable Coverage (v1.7.0)
- ✅ **Overall**: 80%+
- ✅ **NetworkPolicy Package**: 75%+
- ✅ **Controller Package**: 70%+
- ✅ **Critical Files** (git_cli, git_api, reconciliation_single): 90%+

### Quality Metrics
- ✅ All tests pass consistently (no flaky tests)
- ✅ Table-driven tests for complex functions
- ✅ Mocks properly isolated
- ✅ Test execution time < 5 seconds
- ✅ No test interdependencies

---

## 📝 **Notes**

### Files to Skip (Low Priority)
- `network_policy_constants.go` - Constants don't need tests
- `reconciler_interface.go` - Interface definitions
- `zz_generated.deepcopy.go` - Generated code
- `cmd/main.go` - Application entry point (integration tests cover this)

### Testing Tools
- **Framework**: Go standard `testing` package
- **Assertions**: `github.com/stretchr/testify/assert`
- **Requirements**: `github.com/stretchr/testify/require`
- **Mocking**: `sigs.k8s.io/controller-runtime/pkg/client/fake`
- **HTTP**: `net/http/httptest`
- **Filesystem**: `github.com/spf13/afero` (if needed)

---

**Next Step**: Start with Phase 1 (Critical Security Tests) - `git_cli_test.go`

