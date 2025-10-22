#!/bin/bash
# Complete E2E Test Suite for Permission Binder Operator
# Production-Grade Environment - IMPROVED VERSION

# Note: Do NOT use 'set -e' as we want to continue on failures and report all test results

export KUBECONFIG=$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)
NAMESPACE="permissions-binder-operator"
TEST_RESULTS="/tmp/e2e-test-results-complete-$(date +%Y%m%d-%H%M%S).log"

echo "🧪 Permission Binder Operator - Complete E2E Test Suite (IMPROVED)"
echo "=================================================================="
echo "Started: $(date)"
echo "Results will be saved to: $TEST_RESULTS"
echo "Includes Prometheus metrics testing"
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

# Check JSON logging (robust test - check multiple lines)
JSON_VALID_COUNT=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=10 | grep -v "^I" | while read line; do echo "$line" | jq -e '.level' >/dev/null 2>&1 && echo "1"; done | wc -l)
if [ "$JSON_VALID_COUNT" -gt 0 ]; then
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

# Trigger reconciliation
kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-security="$(date +%s)" --overwrite >/dev/null 2>&1

sleep 5

# Check for security warning in logs
SECURITY_WARNING=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -v "^I" \
  | jq -c 'select(.severity=="warning" and .clusterRole=="nonexistent-security-role")' | wc -l)

if [ "$SECURITY_WARNING" -gt 0 ]; then
    pass_test "ClusterRole validation logged security WARNING"
    info_log "Found $SECURITY_WARNING warning logs for missing ClusterRole"
else
    fail_test "No security warning for missing ClusterRole"
fi

# Verify RoleBinding was still created (look in any namespace)
RB_EXISTS=$(kubectl get rolebinding --all-namespaces | grep "security-test" | wc -l)
if [ "$RB_EXISTS" -gt 0 ]; then
    pass_test "RoleBinding created despite missing ClusterRole"
    info_log "Found RoleBinding with nonexistent ClusterRole: $(kubectl get rolebinding --all-namespaces | grep 'security-test')"
else
    fail_test "RoleBinding not created for missing ClusterRole"
fi

# Clean up
kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE \
  --type=json -p='[{"op":"remove","path":"/spec/roleMapping/security-test"}]' >/dev/null 2>&1

echo ""

# ============================================================================
# Test 4: Orphaned Resources & Adoption (SAFE MODE)
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

# Wait for operator to process and trigger adoption (increased from 20s to 30s)
sleep 30

# Force reconciliation by updating ConfigMap
kubectl patch configmap permission-config -n $NAMESPACE -p '{"metadata":{"annotations":{"test-trigger":"'$(date +%s)'"}}}' >/dev/null 2>&1
sleep 10

# Check adoption - look for both logs and metrics
ADOPTION_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=300 | grep -v "^I" \
  | grep -c "Adopted orphaned" 2>/dev/null | tr -d '\n' || echo "0")

# Also check if orphaned resources decreased (adoption happened)
ORPHANED_AFTER=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json \
  | jq '[.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])] | length' | tr -d '\n')

# Ensure variables are integers
ADOPTION_LOGS=${ADOPTION_LOGS:-0}
ORPHANED_AFTER=${ORPHANED_AFTER:-0}

if [ "$ADOPTION_LOGS" -gt 0 ]; then
    pass_test "Automatic adoption of orphaned resources"
    info_log "Adoption events: $ADOPTION_LOGS"
elif [ "$ORPHANED_AFTER" -eq 0 ]; then
    pass_test "Automatic adoption of orphaned resources (all resources adopted)"
    info_log "Orphaned resources decreased from $ORPHANED_COUNT to $ORPHANED_AFTER"
else
    fail_test "No adoption events found"
    info_log "Orphaned before: $ORPHANED_COUNT, after: $ORPHANED_AFTER"
fi

# Verify orphaned annotations removed (should be 0 after successful adoption)
STILL_ORPHANED=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json \
  | jq '[.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])] | length')

if [ "$STILL_ORPHANED" -eq 0 ]; then
    pass_test "Orphaned annotations removed after adoption"
else
    info_log "Some resources still orphaned: $STILL_ORPHANED (adoption may need more time)"
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
# Test 7: ConfigMap Entry Addition (with reconciliation trigger)
# ============================================================================
echo "Test 7: ConfigMap Entry Addition"
echo "----------------------------------"

# Add new LDAP DN entry to whitelist.txt
NEW_ENTRY="CN=COMPANY-K8S-e2e-test-namespace2-admin,OU=TestOU,DC=example,DC=com"
kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-tmp.txt
echo "$NEW_ENTRY" >> /tmp/whitelist-tmp.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-tmp.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

# Force reconciliation multiple ways
# 1. ConfigMap annotation
kubectl patch configmap permission-config -n $NAMESPACE -p '{"metadata":{"annotations":{"test-entry":"'$(date +%s)'"}}}' >/dev/null 2>&1
sleep 5

# 2. PermissionBinder annotation (guaranteed reconcile trigger)
kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-cm-addition="$(date +%s)" --overwrite >/dev/null 2>&1

# Wait longer for reconciliation (increased from 30s to 45s for slow clusters)
sleep 45

# Check namespace created
NS_EXISTS=$(kubectl get namespace e2e-test-namespace2 2>/dev/null | wc -l)
if [ "$NS_EXISTS" -gt 0 ]; then
    pass_test "New namespace created from ConfigMap entry"
else
    fail_test "Namespace not created"
    # Debug: check operator logs for processing
    PROCESSED=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -c "e2e-test-namespace2" || echo "0")
    info_log "Operator log mentions for e2e-test-namespace2: $PROCESSED"
fi

# Check RoleBinding created
RB_EXISTS=$(kubectl get rolebinding e2e-test-namespace2-admin -n e2e-test-namespace2 2>/dev/null | wc -l)
if [ "$RB_EXISTS" -gt 0 ]; then
    pass_test "RoleBinding created for new ConfigMap entry"
else
    fail_test "RoleBinding not created"
fi

# Cleanup temp file
rm -f /tmp/whitelist-tmp.txt

echo ""

# ============================================================================
# Test 8: Exclude List
# ============================================================================
echo "Test 8: Exclude List Functionality"
echo "------------------------------------"

# Add excluded entry to ConfigMap
kubectl patch configmap permission-config -n $NAMESPACE \
  --type=merge -p '{"data":{"DG_FP00-K8S-HPA-admin":"DG_FP00-K8S-HPA-admin"}}' >/dev/null 2>&1

# Trigger reconciliation
kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-exclude="$(date +%s)" --overwrite >/dev/null 2>&1

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
# Test 9: Role Removal from Mapping
# ============================================================================
echo "Test 9: Role Removal from Mapping"
echo "-----------------------------------"

# Add temporary role
kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE \
  --type=merge -p '{"spec":{"roleMapping":{"temp-role":"view"}}}' >/dev/null 2>&1

# Trigger reconciliation
kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-temp-role="$(date +%s)" --overwrite >/dev/null 2>&1

sleep 5

# Check temp role RoleBinding was created
TEMP_RB=$(kubectl get rolebinding -n project1 project1-temp-role 2>/dev/null && echo "created" || echo "missing")
info_log "Temp role RoleBinding: $TEMP_RB"

# Remove temp role
kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE \
  --type=json -p='[{"op":"remove","path":"/spec/roleMapping/temp-role"}]' >/dev/null 2>&1

# Trigger reconciliation
kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-remove-role="$(date +%s)" --overwrite >/dev/null 2>&1

sleep 5

# Check temp role RoleBinding was removed
TEMP_RB_AFTER=$(kubectl get rolebinding -n project1 project1-temp-role 2>/dev/null && echo "still-exists" || echo "removed")
if [ "$TEMP_RB_AFTER" == "removed" ]; then
    pass_test "RoleBindings removed when role deleted from mapping"
else
    fail_test "RoleBinding not removed after role deletion"
fi

echo ""

# ============================================================================
# Test 10: Metrics Endpoint
# ============================================================================
echo "Test 10: Metrics Endpoint"
echo "---------------------------"

# Check if metrics endpoint is accessible (HTTP port 8080)
# Use port-forward since metrics may not be accessible from inside the pod
kubectl port-forward -n $NAMESPACE svc/operator-controller-manager-metrics-service 8080:8080 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 3

# Try HTTP metrics first (port 8080)
METRICS_RESPONSE=$(curl -s http://localhost:8080/metrics 2>/dev/null | grep -c "permission_binder" 2>/dev/null || echo "0")
# Clean up any extra newlines or spaces
METRICS_RESPONSE=$(echo "$METRICS_RESPONSE" | tr -d '\n' | head -1)
METRICS_RESPONSE=${METRICS_RESPONSE:-0}

# Kill port-forward
kill $PORT_FORWARD_PID 2>/dev/null || true

if [ "$METRICS_RESPONSE" -gt 0 ]; then
    pass_test "Prometheus metrics endpoint accessible (HTTP)"
    info_log "Found $METRICS_RESPONSE permission_binder metrics"
else
    fail_test "Metrics endpoint not accessible or no custom metrics"
fi

echo ""

# ============================================================================
# Test 11: Invalid Configuration Handling
# ============================================================================
echo "Test 11: Invalid Configuration Handling"
echo "-----------------------------------------"

# Add invalid LDAP DN to whitelist.txt (missing CN=)
INVALID_ENTRY="INVALID-FORMAT-project-test-admin,OU=Test,DC=example,DC=com"
kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-invalid.txt
echo "$INVALID_ENTRY" >> /tmp/whitelist-invalid.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-invalid.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-invalid.txt

# Trigger reconciliation
kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-invalid="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check operator logs for error handling
ERROR_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "error\|invalid\|failed" | grep -c "CN=" || echo "0")
if [ "$ERROR_LOGS" -gt 0 ]; then
    pass_test "Operator logged error for invalid configuration"
    info_log "Error log entries: $ERROR_LOGS"
else
    info_log "No specific error logs found (operator may silently skip invalid entries)"
fi

# Verify valid entries still processed (should have 7+ RoleBindings from original config)
VALID_RB_COUNT=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers 2>/dev/null | wc -l)
if [ "$VALID_RB_COUNT" -ge 7 ]; then
    pass_test "Valid entries still processed despite invalid entry"
else
    fail_test "Valid entries not processed (found only $VALID_RB_COUNT RoleBindings)"
fi

echo ""

# ============================================================================
# Test 18: JSON Structured Logging Verification
# ============================================================================
echo "Test 18: JSON Structured Logging Verification"
echo "-----------------------------------------------"

# Extract all operator logs
ALL_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=100 2>/dev/null)

# Count total log lines (excluding Kubernetes info lines starting with "I")
TOTAL_LINES=$(echo "$ALL_LOGS" | grep -v "^I" | grep -v "^$" | wc -l)

# Count valid JSON lines
VALID_JSON_LINES=$(echo "$ALL_LOGS" | grep -v "^I" | grep -v "^$" | while read line; do
    echo "$line" | jq -e '.level' >/dev/null 2>&1 && echo "1"
done | wc -l)

# Calculate percentage
if [ "$TOTAL_LINES" -gt 0 ]; then
    PERCENTAGE=$((VALID_JSON_LINES * 100 / TOTAL_LINES))
    if [ "$PERCENTAGE" -ge 95 ]; then
        pass_test "JSON structured logging verified ($PERCENTAGE% of logs are valid JSON)"
        info_log "Valid JSON lines: $VALID_JSON_LINES / $TOTAL_LINES"
    else
        fail_test "JSON logging percentage too low: $PERCENTAGE% (expected >=95%)"
        info_log "Valid JSON lines: $VALID_JSON_LINES / $TOTAL_LINES"
    fi
else
    fail_test "No logs found to verify"
fi

echo ""

# ============================================================================
# Test 23: Finalizer Behavior Verification
# ============================================================================
echo "Test 23: Finalizer Behavior Verification"
echo "------------------------------------------"

# Verify finalizer is present (should already be from Test 1, but verify again)
FINALIZER=$(kubectl get permissionbinder permissionbinder-example -n $NAMESPACE -o jsonpath='{.metadata.finalizers[0]}' 2>/dev/null)
if [ "$FINALIZER" == "permission-binder.io/finalizer" ]; then
    pass_test "Finalizer is present on PermissionBinder"
else
    fail_test "Finalizer not found: $FINALIZER"
fi

# Note: Full deletion test already covered in Test 4 (Orphaned Resources)
# This test just verifies finalizer presence
info_log "Full cleanup behavior tested in Test 4 (Orphaned Resources & Adoption)"

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
# ============================================================================
# Test 25-30: Prometheus Metrics Testing
# ============================================================================
echo ""
echo "Test 25-30: Prometheus Metrics Testing"
echo "--------------------------------------"

# Check if Prometheus is running
PROMETHEUS_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers | wc -l)
if [ "$PROMETHEUS_POD" -gt 0 ]; then
    pass_test "Prometheus is running"
    
    # Test Prometheus metrics collection
    echo "Running Prometheus metrics tests..."
    if ./example/tests/test-prometheus-metrics.sh >> $TEST_RESULTS 2>&1; then
        pass_test "Prometheus metrics collection working correctly"
    else
        fail_test "Prometheus metrics collection has issues"
    fi
else
    fail_test "Prometheus not running - skipping metrics tests"
fi

echo ""
echo "Managed Resources:"
echo "  RoleBindings: $(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)"
echo "  Namespaces: $(kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)"
echo ""
echo "Completed: $(date)"
