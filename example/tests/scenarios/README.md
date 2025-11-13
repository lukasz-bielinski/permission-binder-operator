# E2E Test Scenarios

## Overview

Each test scenario is documented in a separate file for easy navigation and faster reading.

**Structure**: 1 scenario = 1 file = 1 implementation

- **Scenario file**: `XX-test-name.md` (documentation)
- **Implementation file**: `../test-implementations/test-XX-test-name.sh` (bash script)

## Quick Navigation

### Pre-Test {#pre-test}
- [Pre-Test: Initial State Verification](00-pre-test.md)

### Basic Functionality (Tests 1-11) {#basic-functionality-tests-1-11}
- [Test 1: Role Mapping Changes](01-role-mapping-changes.md)
- [Test 2: Prefix Changes](02-prefix-changes.md)
- [Test 3: Exclude List Changes](03-exclude-list-changes.md)
- [Test 4: ConfigMap Changes - Addition](04-configmap-changes---addition.md)
- [Test 5: ConfigMap Changes - Removal](05-configmap-changes---removal.md)
- [Test 6: Role Removal from Mapping](06-role-removal-from-mapping.md)
- [Test 7: Namespace Protection](07-namespace-protection.md)
- [Test 8: PermissionBinder Deletion (SAFE MODE)](08-permissionbinder-deletion-safe-mode.md)
- [Test 9: Operator Restart Recovery](09-operator-restart-recovery.md)
- [Test 10: Conflict Handling](10-conflict-handling.md)
- [Test 11: Invalid Configuration Handling](11-invalid-configuration-handling.md)

### Security & Reliability (Tests 12-24) {#security--reliability-tests-12-24}
- [Test 12: Multi-Architecture Verification](12-multi-architecture-verification.md)
- [Test 13: Non-Existent ClusterRole (Security)](13-non-existent-clusterrole-security.md)
- [Test 14: Orphaned Resources Adoption](14-orphaned-resources-adoption.md)
- [Test 15: Manual RoleBinding Modification (Protection)](15-manual-rolebinding-modification-protection.md)
- [Test 16: Operator Permission Loss (Security)](16-operator-permission-loss-security.md)
- [Test 17: Partial Failure Recovery (Reliability)](17-partial-failure-recovery-reliability.md)
- [Test 18: JSON Structured Logging Verification (Audit)](18-json-structured-logging-verification-audit.md)
- [Test 19: Concurrent ConfigMap Changes (Race Conditions)](19-concurrent-configmap-changes-race-conditions.md)
- [Test 20: ConfigMap Corruption Handling](20-configmap-corruption-handling.md)
- [Test 21: Network Failure Simulation](21-network-failure-simulation.md)
- [Test 22: Metrics Endpoint Verification](22-metrics-endpoint-verification.md)
- [Test 23: Finalizer Behavior Verification](23-finalizer-behavior-verification.md)
- [Test 24: Large ConfigMap Handling](24-large-configmap-handling.md)

### Metrics & Monitoring (Tests 25-30) {#metrics--monitoring-tests-25-30}
- [Test 25: Prometheus Metrics Collection](25-prometheus-metrics-collection.md)
- [Test 26: Metrics Update on Role Mapping Changes](26-metrics-update-on-role-mapping-changes.md)
- [Test 27: Metrics Update on ConfigMap Changes](27-metrics-update-on-configmap-changes.md)
- [Test 28: Orphaned Resources Metrics](28-orphaned-resources-metrics.md)
- [Test 29: ConfigMap Processing Metrics](29-configmap-processing-metrics.md)
- [Test 30: Adoption Events Metrics](30-adoption-events-metrics.md)

### ServiceAccount Management (Tests 31-41) {#serviceaccount-management-tests-31-41}
- [Test 31: ServiceAccount Creation](31-serviceaccount-creation.md)
- [Test 32: ServiceAccount Naming Pattern](32-serviceaccount-naming-pattern.md)
- [Test 33: ServiceAccount Idempotency](33-serviceaccount-idempotency.md)
- [Test 34: ServiceAccount Status Tracking](34-serviceaccount-status-tracking.md)
- [Test 35: ServiceAccount Protection (SAFE MODE)](35-serviceaccount-protection-safe-mode.md)
- [Test 36: ServiceAccount Deletion and Cleanup (Orphaned RoleBindings)](36-serviceaccount-deletion-and-cleanup-orphaned-rolebindings.md)
- [Test 37: Cross-Namespace ServiceAccount References](37-cross-namespace-serviceaccount-references.md)
- [Test 38: Multiple ServiceAccounts per Namespace (Scaling)](38-multiple-serviceaccounts-per-namespace-scaling.md)
- [Test 39: ServiceAccount Special Characters and Edge Cases](39-serviceaccount-special-characters-and-edge-cases.md)
- [Test 40: ServiceAccount Recreation After Deletion](40-serviceaccount-recreation-after-deletion.md)
- [Test 41: ServiceAccount Permission Updates via ConfigMap](41-serviceaccount-permission-updates-via-configmap.md)

### Bug Fixes (Tests 42-43) {#bug-fixes-tests-42-43}
- [Test 42: RoleBindings with Hyphenated Roles (Bug Fix v1.5.2)](42-rolebindings-with-hyphenated-roles-bug-fix-v152.md)
- [Test 43: Invalid Whitelist Entry Handling (Bug Fix v1.5.3)](43-invalid-whitelist-entry-handling-bug-fix-v153.md)

### NetworkPolicy Management (Tests 44-62) {#networkpolicy-management-tests-44-62}
- [Test 44: NetworkPolicy - Variant A (New File from Template)](44-networkpolicy---variant-a-new-file-from-template.md)
- [Test 45: NetworkPolicy - Variant B (Backup Existing Template-based Policy)](45-networkpolicy---variant-b-backup-existing-template-based-policy.md)
- [Test 46: NetworkPolicy - Drift Detection](46-networkpolicy---drift-detection.md)
- [Test 47: NetworkPolicy - Exclude Lists](47-networkpolicy---exclude-lists.md)
- [Test 48: NetworkPolicy - Stale PR Detection](48-networkpolicy---stale-pr-detection.md)
- [Test 49: NetworkPolicy - Auto-Merge PR](49-networkpolicy---auto-merge-pr.md)
- [Test 50: NetworkPolicy - Metrics Verification](50-networkpolicy---metrics-verification.md)
- [Test 51: NetworkPolicy - Rate Limiting Handling](51-networkpolicy---rate-limiting-handling.md)
- [Test 52: NetworkPolicy - Variant C (Backup Non-Template)](52-networkpolicy---variant-c-backup-non-template.md)
- [Test 53: NetworkPolicy - Git Operations Failures](53-networkpolicy---git-operations-failures.md)
- [Test 54: NetworkPolicy - PR State Transitions](54-networkpolicy---pr-state-transitions.md)
- [Test 55: NetworkPolicy - Multiple PermissionBinders Validation](55-networkpolicy---multiple-permissionbinders-validation.md)
- [Test 56: NetworkPolicy - Template Changes Detection](56-networkpolicy---template-changes-detection.md)
- [Test 59: NetworkPolicy - Read-Only Repository Access](59-networkpolicy---read-only-repository-access.md)
- [Test 60: NetworkPolicy - Disabled Mode](60-networkpolicy---disabled-mode.md)
- [Test 61: NetworkPolicy - Namespace Removal Cleanup](61-networkpolicy---namespace-removal-cleanup.md)
- [Test 62: NetworkPolicy - High Frequency Reconciliation](62-networkpolicy---high-frequency-reconciliation.md)

## Adding New Tests

See [ADDING_NEW_TESTS.md](../ADDING_NEW_TESTS.md) for step-by-step guide on adding new tests.

## Test Coverage

See [TEST_COVERAGE_CHECKLIST.md](../TEST_COVERAGE_CHECKLIST.md) for coverage checklist and gaps.
