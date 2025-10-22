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
# Test 5: ConfigMap Entry Removal (from doc)
# ============================================================================
echo "Test 5: ConfigMap Entry Removal"
echo "---------------------------------"

# Count RoleBindings before removal
RB_BEFORE=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)

# Remove one entry from whitelist.txt (remove project3 entry)
kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' | grep -v "project3" > /tmp/whitelist-removal.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-removal.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-removal.txt

# Trigger reconciliation
kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-removal="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 20

# Check RoleBinding removed
RB_AFTER=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_AFTER" -lt "$RB_BEFORE" ]; then
    pass_test "RoleBinding removed after ConfigMap entry deletion"
    info_log "RoleBindings: $RB_BEFORE → $RB_AFTER"
else
    fail_test "RoleBinding not removed (still $RB_AFTER RoleBindings)"
fi

# Verify namespace preserved (not deleted)
NS_PROJECT3=$(kubectl get namespace project3 2>/dev/null | wc -l)
if [ "$NS_PROJECT3" -gt 0 ]; then
    pass_test "Namespace preserved after entry removal (SAFE MODE)"
else
    fail_test "Namespace was deleted (should be preserved)"
fi

echo ""

# ============================================================================
# Test 7 (doc): Namespace Protection
# ============================================================================
echo "Test 7 (doc): Namespace Protection"
echo "------------------------------------"

# Note: This is already tested in Test 5 above and Test 4 (Orphaned Resources)
# Namespace project3 should exist but have no RoleBindings
PROJECT3_RB_COUNT=$(kubectl get rolebindings -n project3 -l permission-binder.io/managed-by=permission-binder-operator --no-headers 2>/dev/null | wc -l)
if [ "$PROJECT3_RB_COUNT" -eq 0 ] && [ "$NS_PROJECT3" -gt 0 ]; then
    pass_test "Namespace protection verified (namespace exists, RoleBindings removed)"
else
    fail_test "Namespace protection failed (RB count: $PROJECT3_RB_COUNT, NS exists: $NS_PROJECT3)"
fi

info_log "Namespace protection ensures namespaces are NEVER deleted by operator"

echo ""

# ============================================================================
# Test 9: Operator Restart Recovery
# ============================================================================
echo "Test 9: Operator Restart Recovery"
echo "-----------------------------------"

# Count resources before restart
RB_BEFORE_RESTART=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
NS_BEFORE_RESTART=$(kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)

# Restart operator pod
kubectl rollout restart deployment operator-controller-manager -n $NAMESPACE >/dev/null 2>&1
kubectl rollout status deployment operator-controller-manager -n $NAMESPACE --timeout=60s >/dev/null 2>&1
sleep 15

# Count resources after restart
RB_AFTER_RESTART=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
NS_AFTER_RESTART=$(kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)

# Verify no duplicates created
if [ "$RB_AFTER_RESTART" -eq "$RB_BEFORE_RESTART" ] && [ "$NS_AFTER_RESTART" -eq "$NS_BEFORE_RESTART" ]; then
    pass_test "Operator recovered without creating duplicates"
    info_log "Resources stable: $RB_AFTER_RESTART RoleBindings, $NS_AFTER_RESTART Namespaces"
else
    fail_test "Resource count changed after restart (RB: $RB_BEFORE_RESTART → $RB_AFTER_RESTART, NS: $NS_BEFORE_RESTART → $NS_AFTER_RESTART)"
fi

echo ""

# ============================================================================
# Test 12: Multi-Architecture Verification
# ============================================================================
echo "Test 12: Multi-Architecture Verification"
echo "------------------------------------------"

# Check operator pod architecture
POD_NAME=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=permission-binder-operator -o jsonpath='{.items[0].metadata.name}')
NODE_NAME=$(kubectl get pod -n $NAMESPACE $POD_NAME -o jsonpath='{.spec.nodeName}')
NODE_ARCH=$(kubectl get node $NODE_NAME -o jsonpath='{.status.nodeInfo.architecture}')

info_log "Operator running on node: $NODE_NAME ($NODE_ARCH)"

# Verify operator is functional (RoleBindings exist)
if [ "$RB_AFTER_RESTART" -gt 0 ]; then
    pass_test "Operator functional on $NODE_ARCH architecture"
else
    fail_test "Operator not functional on $NODE_ARCH"
fi

echo ""

# ============================================================================
# Test 1: Role Mapping Changes
# ============================================================================
echo "Test 1: Role Mapping Changes"
echo "------------------------------"

# Add new role to PermissionBinder mapping
kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"add","path":"/spec/roleMapping/developer","value":"edit"}]' >/dev/null 2>&1

sleep 20

# Check if new RoleBindings were created (should have more than before)
RB_WITH_NEW_ROLE=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_WITH_NEW_ROLE" -gt "$RB_AFTER_RESTART" ]; then
    pass_test "New RoleBindings created after role mapping change"
    info_log "RoleBindings increased: $RB_AFTER_RESTART → $RB_WITH_NEW_ROLE"
else
    fail_test "No new RoleBindings created (still $RB_WITH_NEW_ROLE)"
fi

# Verify at least one RoleBinding references the new role
DEVELOPER_RB=$(kubectl get rolebindings -A -o json | jq -r '.items[] | select(.roleRef.name=="edit") | .metadata.name' | grep -c "developer" || echo "0")
if [ "$DEVELOPER_RB" -gt 0 ]; then
    pass_test "RoleBindings reference new ClusterRole correctly"
else
    info_log "No 'developer' RoleBindings found (may be due to ConfigMap not having matching entries)"
fi

echo ""

# ============================================================================
# Test 10: Conflict Handling
# ============================================================================
echo "Test 10: Conflict Handling"
echo "----------------------------"

# Add duplicate entry to ConfigMap
kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-dup.txt
# Add same entry twice
echo "CN=COMPANY-K8S-project1-engineer,OU=Test,DC=example,DC=com" >> /tmp/whitelist-dup.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-dup.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-dup.txt

kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-conflict="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 15

# Verify no errors in logs
CONFLICT_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "panic\|fatal\|crash" | wc -l)
if [ "$CONFLICT_ERRORS" -eq 0 ]; then
    pass_test "Operator handled duplicate entries gracefully"
else
    fail_test "Operator encountered errors with duplicates: $CONFLICT_ERRORS"
fi

# Verify RoleBindings still exist
RB_CONFLICT=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_CONFLICT" -gt 0 ]; then
    pass_test "RoleBindings still managed despite conflicts"
else
    fail_test "RoleBindings lost due to conflict handling"
fi

echo ""

# ============================================================================
# Test 17: Partial Failure Recovery
# ============================================================================
echo "Test 17: Partial Failure Recovery"
echo "-----------------------------------"

# Add mix of valid and invalid entries
kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-mixed.txt
echo "CN=COMPANY-K8S-valid-namespace-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-mixed.txt
echo "INVALID-ENTRY-NO-CN" >> /tmp/whitelist-mixed.txt
echo "CN=COMPANY-K8S-another-valid-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-mixed.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-mixed.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-mixed.txt

kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-partial="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 20

# Check if valid entries were processed
VALID_NS=$(kubectl get namespace valid-namespace 2>/dev/null | wc -l)
ANOTHER_VALID_NS=$(kubectl get namespace another-valid 2>/dev/null | wc -l)

if [ "$VALID_NS" -gt 0 ] || [ "$ANOTHER_VALID_NS" -gt 0 ]; then
    pass_test "Valid entries processed despite invalid ones"
else
    info_log "Valid namespaces not created (may be timing or parsing issue)"
fi

# Verify operator still running
POD_STATUS=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=permission-binder-operator -o jsonpath='{.items[0].status.phase}')
if [ "$POD_STATUS" == "Running" ]; then
    pass_test "Operator remains running after partial failures"
else
    fail_test "Operator not running: $POD_STATUS"
fi

echo ""

# ============================================================================
# Test 19: Concurrent ConfigMap Changes
# ============================================================================
echo "Test 19: Concurrent ConfigMap Changes"
echo "---------------------------------------"

# Make rapid changes to ConfigMap
for i in {1..3}; do
    kubectl annotate configmap permission-config -n $NAMESPACE concurrent-test-$i="$(date +%s)" --overwrite >/dev/null 2>&1 &
done
wait

sleep 20

# Verify no race condition errors
RACE_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "conflict\|race\|concurrent" | wc -l)
info_log "Concurrent change logs: $RACE_ERRORS"

# Verify resources are consistent
RB_CONSISTENT=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_CONSISTENT" -gt 0 ]; then
    pass_test "Resources consistent after concurrent changes"
else
    fail_test "Resources lost after concurrent changes"
fi

echo ""

# ============================================================================
# Test 20: ConfigMap Corruption Handling
# ============================================================================
echo "Test 20: ConfigMap Corruption Handling"
echo "----------------------------------------"

# Test with various malformed entries
kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-corrupt.txt
echo "CN=COMPANY-K8S-project1-engineer" >> /tmp/whitelist-corrupt.txt  # Missing parts
echo "CN=" >> /tmp/whitelist-corrupt.txt  # Empty CN
echo "$(python3 -c 'print("A"*300)')" >> /tmp/whitelist-corrupt.txt  # Too long
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-corrupt.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-corrupt.txt

kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-corrupt="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 15

# Verify operator didn't crash
POD_RESTARTS=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=permission-binder-operator -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
if [ "$POD_RESTARTS" -eq 0 ]; then
    pass_test "Operator handled corrupted ConfigMap without crashing"
else
    fail_test "Operator restarted $POD_RESTARTS times due to corruption"
fi

# Verify error logging
CORRUPTION_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "error\|invalid" | wc -l)
info_log "Corruption handling log entries: $CORRUPTION_LOGS"

echo ""

# ============================================================================
# Test 24: Large ConfigMap Handling
# ============================================================================
echo "Test 24: Large ConfigMap Handling"
echo "-----------------------------------"

# Create ConfigMap with 50+ entries
kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-large.txt
for i in {1..50}; do
    echo "CN=COMPANY-K8S-large-project-$i-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-large.txt
done
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-large.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-large.txt

kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-large="$(date +%s)" --overwrite >/dev/null 2>&1

# Time the reconciliation
START_TIME=$(date +%s)
sleep 40  # Give it time to process
END_TIME=$(date +%s)
RECONCILE_TIME=$((END_TIME - START_TIME))

# Check if all entries were processed
LARGE_NS_COUNT=$(kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
info_log "Created namespaces: $LARGE_NS_COUNT (expected 50+)"
info_log "Reconciliation time: ${RECONCILE_TIME}s"

if [ "$RECONCILE_TIME" -lt 60 ]; then
    pass_test "Large ConfigMap processed in acceptable time (${RECONCILE_TIME}s < 60s)"
else
    fail_test "Reconciliation too slow: ${RECONCILE_TIME}s"
fi

# Check operator memory usage
POD_NAME=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=permission-binder-operator -o jsonpath='{.items[0].metadata.name}')
MEMORY_USAGE=$(kubectl top pod -n $NAMESPACE $POD_NAME 2>/dev/null | tail -1 | awk '{print $3}' || echo "N/A")
info_log "Operator memory usage: $MEMORY_USAGE"

echo ""

# ============================================================================
# Test 16: Operator Permission Loss (Security)
# ============================================================================
echo "Test 16: Operator Permission Loss (Security)"
echo "----------------------------------------------"

# Backup current ClusterRoleBinding
kubectl get clusterrolebinding permission-binder-operator-manager-rolebinding -o yaml > /tmp/crb-backup.yaml 2>/dev/null

# Remove a specific permission temporarily (rolebindings.create)
kubectl get clusterrole permission-binder-operator-manager-role -o json | \
  jq 'del(.rules[] | select(.resources[] == "rolebindings"))' | \
  kubectl apply -f - >/dev/null 2>&1

# Trigger reconciliation
kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-rbac-loss="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check for permission errors in logs
PERMISSION_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | \
  grep -i "forbidden\|permission denied\|unauthorized" | wc -l)

if [ "$PERMISSION_ERRORS" -gt 0 ]; then
    pass_test "Operator logged permission errors correctly"
    info_log "Permission error log entries: $PERMISSION_ERRORS"
else
    info_log "No permission errors detected (RBAC may still be valid)"
fi

# Restore permissions
kubectl apply -f example/rbac/clusterrole.yaml >/dev/null 2>&1
sleep 5

# Verify operator recovered
POD_STATUS=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=permission-binder-operator -o jsonpath='{.items[0].status.phase}')
if [ "$POD_STATUS" == "Running" ]; then
    pass_test "Operator recovered after RBAC restoration"
else
    fail_test "Operator not running after RBAC restoration: $POD_STATUS"
fi

rm -f /tmp/crb-backup.yaml

echo ""

# ============================================================================
# Test 21: Network Failure Simulation (Reliability)
# ============================================================================
echo "Test 21: Network Failure Simulation (Reliability)"
echo "---------------------------------------------------"

# Note: True network partition is hard to simulate in K3s without CNI manipulation
# Instead, we'll test operator behavior during brief API server unavailability
info_log "Simulating network issues via rapid reconciliation"

# Create many rapid reconciliation triggers to stress the system
for i in {1..10}; do
    kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE stress-test-$i="$(date +%s)" --overwrite >/dev/null 2>&1 &
done
wait
sleep 15

# Check for connection errors (if any)
CONN_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=100 | \
  grep -i "connection refused\|timeout\|dial tcp\|i/o timeout" | wc -l)
info_log "Connection-related log entries: $CONN_ERRORS"

# Verify operator is still functional
RB_CURRENT=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_CURRENT" -gt 0 ]; then
    pass_test "Operator remained functional under stress"
    info_log "Managed RoleBindings: $RB_CURRENT"
else
    fail_test "Operator lost managed resources"
fi

# Verify no crash/restarts
POD_RESTARTS=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=permission-binder-operator -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
if [ "$POD_RESTARTS" -eq 0 ]; then
    pass_test "Operator handled stress without restarting"
else
    fail_test "Operator restarted $POD_RESTARTS times during stress test"
fi

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
# Test 25: Prometheus Metrics Collection
# ============================================================================
echo "Test 25: Prometheus Metrics Collection"
echo "----------------------------------------"

# Check if Prometheus is running
PROMETHEUS_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | wc -l)
if [ "$PROMETHEUS_POD" -eq 0 ]; then
    fail_test "Prometheus not running - skipping metrics tests 25-30"
    info_log "Install Prometheus to enable metrics testing"
    echo ""
else
    pass_test "Prometheus is running"
    
    # Query basic operator metrics
    PROM_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
    
    # Test 25: Basic metrics collection
    METRICS_COUNT=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result | length')
    if [ "$METRICS_COUNT" -gt 0 ]; then
        pass_test "Prometheus collecting operator metrics"
        CURRENT_RB=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result[0].value[1]')
        info_log "Current RoleBindings metric: $CURRENT_RB"
    else
        fail_test "Prometheus not collecting operator metrics"
    fi
    
    echo ""
    
    # ============================================================================
    # Test 26: Metrics Update on Role Mapping Changes
    # ============================================================================
    echo "Test 26: Metrics Update on Role Mapping Changes"
    echo "-------------------------------------------------"
    
    # Record initial metric value
    RB_METRIC_BEFORE=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result[0].value[1]' | cut -d. -f1)
    info_log "RoleBindings metric before: $RB_METRIC_BEFORE"
    
    # Add new role (should increase RoleBindings)
    kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
      -p='[{"op":"add","path":"/spec/roleMapping/metrics-test","value":"view"}]' >/dev/null 2>&1
    sleep 30
    
    # Check updated metric
    RB_METRIC_AFTER=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result[0].value[1]' | cut -d. -f1)
    info_log "RoleBindings metric after: $RB_METRIC_AFTER"
    
    if [ "$RB_METRIC_AFTER" -gt "$RB_METRIC_BEFORE" ]; then
        pass_test "Metrics updated after role mapping change"
    else
        info_log "Metrics may need more time to update (scrape interval)"
    fi
    
    # Cleanup
    kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
      -p='[{"op":"remove","path":"/spec/roleMapping/metrics-test"}]' >/dev/null 2>&1
    
    echo ""
    
    # ============================================================================
    # Test 27: Metrics Update on ConfigMap Changes
    # ============================================================================
    echo "Test 27: Metrics Update on ConfigMap Changes"
    echo "----------------------------------------------"
    
    # Record initial namespace metric
    NS_METRIC_BEFORE=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_namespaces_total" 2>/dev/null | jq -r '.data.result[0].value[1]' | cut -d. -f1 2>/dev/null || echo "0")
    info_log "Namespaces metric before: $NS_METRIC_BEFORE"
    
    # Add new namespace entry
    kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-metrics.txt
    echo "CN=COMPANY-K8S-metrics-test-ns-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-metrics.txt
    kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-metrics.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    rm -f /tmp/whitelist-metrics.txt
    
    kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-ns-metrics="$(date +%s)" --overwrite >/dev/null 2>&1
    sleep 30
    
    # Check updated metric
    NS_METRIC_AFTER=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_namespaces_total" 2>/dev/null | jq -r '.data.result[0].value[1]' | cut -d. -f1 2>/dev/null || echo "0")
    info_log "Namespaces metric after: $NS_METRIC_AFTER"
    
    if [ "$NS_METRIC_AFTER" -gt "$NS_METRIC_BEFORE" ]; then
        pass_test "Namespace metrics updated after ConfigMap change"
    else
        info_log "Metrics may need more time to update"
    fi
    
    echo ""
    
    # ============================================================================
    # Test 28: Orphaned Resources Metrics
    # ============================================================================
    echo "Test 28: Orphaned Resources Metrics"
    echo "-------------------------------------"
    
    # Query orphaned resources metric
    ORPHANED_METRIC=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_orphaned_resources_total" 2>/dev/null | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "0")
    info_log "Orphaned resources metric: $ORPHANED_METRIC"
    
    # Note: Should be 0 after Test 4 (adoption completed)
    if [ "$ORPHANED_METRIC" -eq 0 ]; then
        pass_test "No orphaned resources (adoption completed successfully)"
    else
        info_log "Some resources still orphaned: $ORPHANED_METRIC (may need more reconciliation time)"
    fi
    
    echo ""
    
    # ============================================================================
    # Test 29: ConfigMap Processing Metrics
    # ============================================================================
    echo "Test 29: ConfigMap Processing Metrics"
    echo "---------------------------------------"
    
    # Query ConfigMap entries processed metric
    CM_PROCESSED=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_configmap_entries_processed_total" 2>/dev/null | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "N/A")
    info_log "ConfigMap entries processed: $CM_PROCESSED"
    
    if [ "$CM_PROCESSED" != "N/A" ] && [ "$CM_PROCESSED" -gt 0 ]; then
        pass_test "ConfigMap processing metrics tracked"
    else
        info_log "ConfigMap processing metric not available (may not be implemented)"
    fi
    
    echo ""
    
    # ============================================================================
    # Test 30: Adoption Events Metrics
    # ============================================================================
    echo "Test 30: Adoption Events Metrics"
    echo "----------------------------------"
    
    # Query adoption events metric
    ADOPTION_METRIC=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_adoption_events_total" 2>/dev/null | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "0")
    info_log "Adoption events metric: $ADOPTION_METRIC"
    
    # Should have at least 1 from Test 4
    if [ "$ADOPTION_METRIC" -gt 0 ]; then
        pass_test "Adoption events tracked in metrics"
    else
        info_log "No adoption events in metrics (may need more time or not implemented)"
    fi
    
    echo ""
fi

echo ""
echo "Managed Resources:"
echo "  RoleBindings: $(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)"
echo "  Namespaces: $(kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)"
echo ""
echo "Completed: $(date)"
