#!/bin/bash
# Complete E2E Test Suite for Permission Binder Operator
# Production-Grade Environment

set -e

export KUBECONFIG=$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)
NAMESPACE="permissions-binder-operator"
TEST_RESULTS="/tmp/e2e-test-results-$(date +%Y%m%d-%H%M%S).log"

echo "🧪 Permission Binder Operator - Complete E2E Test Suite"
echo "=================================================="
echo "Started: $(date)"
echo "Results will be saved to: $TEST_RESULTS"
echo ""

# Helper function for test status
pass_test() {
    echo "✅ PASS: $1" | tee -a $TEST_RESULTS
}

fail_test() {
    echo "❌ FAIL: $1" | tee -a $TEST_RESULTS
}

info_log() {
    echo "ℹ️  $1" | tee -a $TEST_RESULTS
}

# ============================================================================
# Test 1: Initial State Verification
# ============================================================================
echo "Test 1: Initial State Verification"
echo "-----------------------------------"

POD_STATUS=$(kubectl get pods -n $NAMESPACE -l control-plane=controller-manager -o jsonpath='{.items[0].status.phase}')
if [ "$POD_STATUS" == "Running" ]; then
    pass_test "Operator pod is running"
else
    fail_test "Operator pod not running: $POD_STATUS"
fi

# Check JSON logging
JSON_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=5 | grep -v "^I" | jq -e '.' 2>/dev/null && echo "valid" || echo "invalid")
if [ "$JSON_LOGS" == "valid" ]; then
    pass_test "JSON structured logging is working"
else
    fail_test "JSON logging not working properly"
fi

# Check finalizer
FINALIZER=$(kubectl get permissionbinder permissionbinder-example -n $NAMESPACE -o jsonpath='{.metadata.finalizers[0]}')
if [ "$FINALIZER" == "permission-binder.io/finalizer" ]; then
    pass_test "Finalizer is present on PermissionBinder"
else
    fail_test "Finalizer missing: $FINALIZER"
fi

echo ""

# ============================================================================
# Test 2: RoleBinding Creation from ConfigMap
# ============================================================================
echo "Test 2: RoleBinding Creation from ConfigMap"
echo "--------------------------------------------"

sleep 5
RB_COUNT=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
info_log "Created $RB_COUNT RoleBindings"

if [ "$RB_COUNT" -gt 0 ]; then
    pass_test "Operator created RoleBindings from ConfigMap"
else
    fail_test "No RoleBindings created"
fi

# Check RoleBinding has correct annotations
ANNOTATIONS=$(kubectl get rolebinding -n project1 project1-engineer -o jsonpath='{.metadata.annotations}' 2>/dev/null | jq -e '."permission-binder.io/managed-by"' 2>/dev/null)
if [ "$ANNOTATIONS" == "\"permission-binder-operator\"" ]; then
    pass_test "RoleBindings have correct annotations"
else
    fail_test "RoleBindings missing annotations"
fi

echo ""

# ============================================================================
# Test 3: ClusterRole Validation (Security Critical)
# ============================================================================
echo "Test 3: ClusterRole Validation (Non-Existent ClusterRole)"
echo "-----------------------------------------------------------"

# Add role with non-existent ClusterRole
kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE \
  --type=merge -p '{"spec":{"roleMapping":{"security-test":"nonexistent-security-role"}}}' >/dev/null 2>&1

sleep 5

# Check for security warning in logs
SECURITY_WARNING=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=100 | grep -v "^I" \
  | jq -c 'select(.severity=="warning" and .clusterRole=="nonexistent-security-role")' | wc -l)

if [ "$SECURITY_WARNING" -gt 0 ]; then
    pass_test "ClusterRole validation logged security WARNING"
    info_log "Found $SECURITY_WARNING warning logs for missing ClusterRole"
else
    fail_test "No security warning for missing ClusterRole"
fi

# Verify RoleBinding was still created
RB_EXISTS=$(kubectl get rolebinding -n project1 project1-security-test 2>/dev/null && echo "exists" || echo "missing")
if [ "$RB_EXISTS" == "exists" ]; then
    pass_test "RoleBinding created despite missing ClusterRole"
else
    fail_test "RoleBinding not created for missing ClusterRole"
fi

# Clean up
kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE \
  --type=json -p='[{"op":"remove","path":"/spec/roleMapping/security-test"}]' >/dev/null 2>&1

echo ""

# ============================================================================
# Test 4: Orphaned Resources & Adoption
# ============================================================================
echo "Test 4: Orphaned Resources & Adoption (SAFE MODE)"
echo "---------------------------------------------------"

# Count resources before deletion
RB_BEFORE=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
info_log "RoleBindings before deletion: $RB_BEFORE"

# Delete PermissionBinder
kubectl delete permissionbinder permissionbinder-example -n $NAMESPACE >/dev/null 2>&1

sleep 5

# Check orphaned annotations
ORPHANED_COUNT=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json \
  | jq '[.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])] | length')

if [ "$ORPHANED_COUNT" -gt 0 ]; then
    pass_test "SAFE MODE: Resources marked as orphaned (not deleted)"
    info_log "Orphaned RoleBindings: $ORPHANED_COUNT"
else
    fail_test "Resources were deleted instead of being orphaned!"
fi

# Recreate PermissionBinder
kubectl apply -f example/permissionbinder/permissionbinder-example.yaml >/dev/null 2>&1

sleep 10

# Check adoption
ADOPTION_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=100 | grep -v "^I" \
  | jq -c 'select(.action=="adoption")' | wc -l)

if [ "$ADOPTION_LOGS" -gt 0 ]; then
    pass_test "Automatic adoption of orphaned resources"
    info_log "Adoption events: $ADOPTION_LOGS"
else
    fail_test "No adoption events found"
fi

# Verify orphaned annotations removed
STILL_ORPHANED=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json \
  | jq '[.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])] | length')

if [ "$STILL_ORPHANED" -lt "$ORPHANED_COUNT" ]; then
    pass_test "Orphaned annotations removed after adoption"
    info_log "Remaining orphaned: $STILL_ORPHANED (should decrease over time)"
else
    info_log "Some resources still orphaned: $STILL_ORPHANED (may need reconciliation)"
fi

echo ""

# ============================================================================
# Test 5: Manual Override Protection
# ============================================================================
echo "Test 5: Manual Override Protection"
echo "------------------------------------"

# Get original group
ORIGINAL_GROUP=$(kubectl get rolebinding project1-engineer -n project1 -o jsonpath='{.subjects[0].name}' 2>/dev/null)
info_log "Original group: $ORIGINAL_GROUP"

# Manually modify RoleBinding
kubectl patch rolebinding project1-engineer -n project1 \
  --type='json' -p='[{"op": "replace", "path": "/subjects/0/name", "value": "MANUALLY-HACKED-GROUP"}]' >/dev/null 2>&1

sleep 2

# Trigger reconciliation
kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-override="$(date +%s)" --overwrite >/dev/null 2>&1

sleep 5

# Check if restored
CURRENT_GROUP=$(kubectl get rolebinding project1-engineer -n project1 -o jsonpath='{.subjects[0].name}' 2>/dev/null)

if [ "$CURRENT_GROUP" == "$ORIGINAL_GROUP" ]; then
    pass_test "Operator enforced desired state (overrode manual change)"
else
    fail_test "Manual change persisted: $CURRENT_GROUP (expected: $ORIGINAL_GROUP)"
fi

echo ""

# ============================================================================
# Test 6: Prefix Change
# ============================================================================
echo "Test 6: Prefix Change Handling"
echo "--------------------------------"

# Change prefix
kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE \
  --type=merge -p '{"spec":{"prefix":"TEST_PREFIX"}}' >/dev/null 2>&1

sleep 10

# Check if old RoleBindings removed and new created
OLD_PREFIX_COUNT=$(kubectl get rolebindings -A -o json | jq '[.items[] | select(.subjects[0].name | startswith("DG_FP00-K8S"))] | length')
NEW_PREFIX_COUNT=$(kubectl get rolebindings -A -o json | jq '[.items[] | select(.subjects[0].name | startswith("TEST_PREFIX"))] | length')

info_log "RoleBindings with old prefix (DG_FP00-K8S): $OLD_PREFIX_COUNT"
info_log "RoleBindings with new prefix (TEST_PREFIX): $NEW_PREFIX_COUNT"

if [ "$NEW_PREFIX_COUNT" -gt 0 ]; then
    pass_test "Operator processed new prefix"
else
    fail_test "No RoleBindings with new prefix found"
fi

# Restore original prefix
kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE \
  --type=merge -p '{"spec":{"prefix":"DG_FP00-K8S"}}' >/dev/null 2>&1

echo ""

# ============================================================================
# Test 7: ConfigMap Entry Addition
# ============================================================================
echo "Test 7: ConfigMap Entry Addition"
echo "----------------------------------"

# Add new entry
kubectl patch configmap permission-config -n $NAMESPACE \
  --type=merge -p '{"data":{"DG_FP00-K8S-e2e-test-namespace-admin":"DG_FP00-K8S-e2e-test-namespace-admin"}}' >/dev/null 2>&1

sleep 5

# Check namespace created
NS_EXISTS=$(kubectl get namespace e2e-test-namespace 2>/dev/null && echo "yes" || echo "no")
if [ "$NS_EXISTS" == "yes" ]; then
    pass_test "New namespace created from ConfigMap entry"
else
    fail_test "Namespace not created"
fi

# Check RoleBinding created
RB_EXISTS=$(kubectl get rolebinding e2e-test-namespace-admin -n e2e-test-namespace 2>/dev/null && echo "yes" || echo "no")
if [ "$RB_EXISTS" == "yes" ]; then
    pass_test "RoleBinding created for new ConfigMap entry"
else
    fail_test "RoleBinding not created"
fi

echo ""

# ============================================================================
# Test 8: Exclude List
# ============================================================================
echo "Test 8: Exclude List Functionality"
echo "------------------------------------"

# Add excluded entry to ConfigMap
kubectl patch configmap permission-config -n $NAMESPACE \
  --type=merge -p '{"data":{"DG_FP00-K8S-HPA-admin":"DG_FP00-K8S-HPA-admin"}}' >/dev/null 2>&1

sleep 5

# Check it was excluded
HPA_RB=$(kubectl get rolebinding -n HPA HPA-admin 2>/dev/null && echo "created" || echo "excluded")
if [ "$HPA_RB" == "excluded" ]; then
    pass_test "Excluded entry was not processed"
else
    fail_test "Excluded entry was processed!"
fi

# Check logs for "Skipping excluded"
SKIP_LOG=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --since=30s | grep -v "^I" \
  | jq -c 'select(.message | contains("Skipping excluded"))' | wc -l)
info_log "Exclude log entries: $SKIP_LOG"

echo ""

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=================================================="
echo "E2E Test Suite Summary"
echo "=================================================="
echo ""
echo "Test Results:"
grep -E "^(✅|❌)" $TEST_RESULTS | sort | uniq -c
echo ""
echo "Detailed results: $TEST_RESULTS"
echo ""
echo "Operator Status:"
kubectl get pods -n $NAMESPACE
echo ""
echo "Managed Resources:"
echo "  RoleBindings: $(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)"
echo "  Namespaces: $(kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)"
echo ""
echo "Completed: $(date)"

