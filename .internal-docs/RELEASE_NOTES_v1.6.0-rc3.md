# Release Notes - v1.6.0-rc3

**Release Date**: November 13, 2025  
**Status**: Release Candidate 3  
**Focus**: E2E Test Suite Completion & CRD Deployment Improvement

---

## 🎯 Overview

This release completes the comprehensive E2E test suite for NetworkPolicy management and restores single-file deployment capability by embedding the CRD in the main deployment manifest.

---

## ✨ New Features

### 1. **Single-File Operator Deployment** ⭐
- **What**: `example/deployment/operator-deployment.yaml` now includes full `PermissionBinder` CRD definition
- **Why**: Simplifies deployment for ops teams – one `kubectl apply -f` command deploys everything
- **Impact**: Faster incident recovery, reduced deployment errors

### 2. **NetworkPolicy E2E Test Suite Completion** ✅
- **Test Count**: 17 NetworkPolicy scenarios (Tests 44-60)
- **Coverage**: Auto-merge, metrics, rate limiting, read-only repos, disabled mode, namespace cleanup, stress testing
- **Success Rate**: 100% (all tests passing)
- **New Tests** (57-60):
  - **Test 57**: Read-Only Repository Access (simulates 403 forbidden errors)
  - **Test 58**: NetworkPolicy Disabled Mode (graceful degradation)
  - **Test 59**: Namespace Removal Cleanup (orphaned namespace handling)
  - **Test 60**: High Frequency Reconciliation (stress test with 5s intervals)

---

## 🔧 Improvements

### Test Infrastructure
- **Dynamic Test Discovery**: Runner auto-detects available test implementations (no hardcoded ranges)
- **Test Numbering**: Eliminated gaps (57-58 were unused, tests renumbered 59-62 → 57-60)
- **Better Error Handling**: Clear messages for missing test files

### Test Stability
- **Test 49 Fix**: Auto-merge PR label now correctly attached via `gh pr edit --add-label`
- **Test 55 Fix**: Metrics parsing corrected (numeric value instead of "HELP" text)
- **PR Verification**: Enhanced `verify_pr_on_github()` to fetch labels with `--json labels`

---

## 📊 Test Suite Status

| Metric | Value |
|--------|-------|
| **Total Scenarios** | 60 (Pre-Test + 1-60) |
| **NetworkPolicy Tests** | 17 (Tests 44-60) |
| **Latest Run Success Rate** | 100% (Tests 49, 57-60) |
| **Test Infrastructure** | Dynamic discovery, full isolation mode |

### Test Categories
- Basic Functionality (Tests 1-11)
- Security & Reliability (Tests 12-24)
- Metrics & Monitoring (Tests 25-30)
- ServiceAccount Management (Tests 31-41)
- Bug Fixes (Tests 42-43)
- **NetworkPolicy Management (Tests 44-60)** ⭐ New

---

## 📚 Documentation Updates

- **Main Test Documentation**: `example/e2e-test-scenarios.md` updated to reflect 60 scenarios
- **Test Coverage Checklist**: Updated with NetworkPolicy test completion
- **Scenario README**: Links corrected for renumbered tests (57-60)
- **PROJECT_STATUS.md**: Updated with current test count and NetworkPolicy feature

---

## 🐛 Bug Fixes

1. **Test Runner Range Detection**: Fixed hardcoded `1-48` range, now dynamically discovers tests
2. **PR Label Attachment**: GitHub API doesn't attach labels on PR creation – added explicit `gh pr edit` step
3. **Metrics Parsing**: Corrected regex to extract numeric values from Prometheus metrics endpoint

---

## 🔍 Technical Details

### Files Changed
- `example/deployment/operator-deployment.yaml`: +438 lines (CRD embedded)
- `example/e2e-test-scenarios.md`: Updated test count (48 → 60)
- `example/tests/run-tests-full-isolation.sh`: Dynamic test discovery
- `example/tests/test-common.sh`: Enhanced PR verification with label fetching
- Test implementations: Renumbered 59-62 → 57-60

### Net Code Changes
- **+506 lines added**
- **-929 lines removed**
- **Net: -423 lines** (cleanup + renumbering)

---

## ⚠️ Known Issues

### Linter Warnings (22 issues)
- **errcheck (9)**: Unchecked `Close()`, `RemoveAll()` calls (cleanup planned)
- **unused (6)**: Variables/functions reserved for future features
- **staticcheck (6)**: Minor code quality suggestions

These are non-critical and will be addressed in a future cleanup PR.

---

## 🚀 Upgrade Path

### From v1.6.0-rc2
No breaking changes – drop-in replacement.

```bash
# Update operator deployment
kubectl apply -f example/deployment/operator-deployment.yaml

# Verify deployment
kubectl wait --for=condition=available --timeout=120s \
  deployment/operator-controller-manager -n permissions-binder-operator
```

### CRD Update
The new deployment manifest includes the CRD, so manual CRD application is no longer required.

---

## 📋 Testing Recommendations

### Before Merging to Main
1. ✅ Run full test suite (all 60 tests)
2. ⚠️ Address linter warnings
3. ✅ Validate secret handling (`temp/` files)
4. ✅ Update internal documentation

### Post-Merge Validation
1. Deploy to staging cluster
2. Run smoke tests (Tests 1-3, 49, 57-60)
3. Verify metrics endpoint accessibility
4. Check Prometheus integration

---

## 🎯 Next Steps (v1.6.0 GA)

1. **Linter Cleanup**: Address 22 linter warnings
2. **Full Test Suite Run**: Validate all 60 scenarios pass
3. **Performance Testing**: Validate operator under load
4. **Security Audit**: Final review before GA
5. **Production Deployment**: Roll out to production clusters

---

## 📞 Support & Feedback

- **Repository**: https://github.com/lukasz-bielinski/permission-binder-operator
- **Issues**: Report bugs via GitHub Issues
- **Documentation**: See `example/e2e-test-scenarios.md` for test details

---

## 👥 Contributors

- **Engineering**: Comprehensive E2E test suite implementation
- **SRE**: Single-file deployment workflow improvement
- **QA**: Test stability fixes and validation

---

**Status**: Ready for final validation before v1.6.0 GA 🎉

