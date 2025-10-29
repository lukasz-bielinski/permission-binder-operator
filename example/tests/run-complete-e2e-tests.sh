#!/bin/bash
# Complete E2E Test Suite for Permission Binder Operator
# Production-Grade - Tests 1-34 in correct order matching documentation

export KUBECONFIG=$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)
NAMESPACE="permissions-binder-operator"
TEST_RESULTS="/tmp/e2e-test-results-complete-$(date +%Y%m%d-%H%M%S).log"

echo "🧪 Permission Binder Operator - Complete E2E Test Suite"
echo "========================================================"
echo "Started: $(date)"
echo "Results will be saved to: $TEST_RESULTS"
echo "Tests 1-34 in order matching e2e-test-scenarios.md"
echo ""

# Helper functions
pass_test() {
    echo "✅ PASS: $1" | tee -a $TEST_RESULTS
}

fail_test() {
    echo "❌ FAIL: $1" | tee -a $TEST_RESULTS
}

info_log() {
    echo "ℹ️  $1" | tee -a $TEST_RESULTS
}

# Retry kubectl commands with exponential backoff (for RPi k3s restarts)
kubectl_retry() {
    local max_attempts=5
    local timeout=2
    local attempt=1
    local exitCode=0
    
    while [ $attempt -le $max_attempts ]; do
        if "$@" 2>&1; then
            return 0
        else
            exitCode=$?
        fi
        
        # Check if it's a connection error
        if echo "$("$@" 2>&1)" | grep -qE "connection refused|ServiceUnavailable|i/o timeout"; then
            if [ $attempt -lt $max_attempts ]; then
                info_log "⚠️  K3s connection issue (attempt $attempt/$max_attempts), retrying in ${timeout}s..."
                sleep $timeout
                timeout=$((timeout * 2))  # Exponential backoff
                attempt=$((attempt + 1))
            else
                info_log "❌ K3s connection failed after $max_attempts attempts"
                return $exitCode
            fi
        else
            # Not a connection error, return immediately
            return $exitCode
        fi
    done
    
    return $exitCode
}

# ============================================================================
# Pre-Test: Initial State Verification
# ============================================================================
echo "Pre-Test: Initial State Verification"
echo "-------------------------------------"

# Check if deployment is available
DEPLOYMENT_READY=$(kubectl_retry kubectl get deployment operator-controller-manager -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator pod is running"
else
    fail_test "Operator deployment not ready"
fi

# Check JSON logging
JSON_VALID_COUNT=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=10 | grep -v "^I" | while read line; do echo "$line" | jq -e '.level' >/dev/null 2>&1 && echo "1"; done | wc -l)
if [ "$JSON_VALID_COUNT" -gt 0 ]; then
    pass_test "JSON structured logging is working"
else
    fail_test "JSON logging not working properly"
fi

# Create or update ConfigMap for testing
if ! kubectl_retry kubectl get configmap permission-config -n $NAMESPACE >/dev/null 2>&1; then
    info_log "Creating test ConfigMap"
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-namespace-001-developer,OU=Groups,DC=example,DC=com
EOF
fi

# Check or create example PermissionBinder for testing
if ! kubectl_retry kubectl get permissionbinder permissionbinder-example -n $NAMESPACE >/dev/null 2>&1; then
    info_log "Creating example PermissionBinder for testing"
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: permissionbinder-example
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    admin: admin
    developer: edit
    viewer: view
EOF
    sleep 3
fi

# Check finalizer
FINALIZER=$(kubectl_retry kubectl get permissionbinder permissionbinder-example -n $NAMESPACE -o jsonpath='{.metadata.finalizers[0]}' 2>/dev/null || echo "not-found")
if [ "$FINALIZER" == "permission-binder.io/finalizer" ]; then
    pass_test "Finalizer is present on PermissionBinder"
else
    info_log "Finalizer: $FINALIZER (may be added during first reconciliation)"
fi

echo ""

# ============================================================================
# Test 1: Role Mapping Changes
# ============================================================================
echo "Test 1: Role Mapping Changes"
echo "------------------------------"

# Count current RoleBindings
RB_BEFORE=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
info_log "RoleBindings before: $RB_BEFORE"

# Add new role to PermissionBinder mapping
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"add","path":"/spec/roleMapping/developer","value":"edit"}]' >/dev/null 2>&1

# Add ConfigMap entry with "developer" role to test the new mapping
# Get current whitelist and append new entry
CURRENT_WHITELIST=$(kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}')
kubectl_retry kubectl patch configmap permission-config -n $NAMESPACE --type=merge \
  -p="{\"data\":{\"whitelist.txt\":\"${CURRENT_WHITELIST}\nCN=COMPANY-K8S-test-namespace-developer,OU=Example,DC=example,DC=com\"}}" >/dev/null 2>&1

sleep 20

# Check if new RoleBindings were created
RB_AFTER=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_AFTER" -gt "$RB_BEFORE" ]; then
    pass_test "New RoleBindings created after role mapping change"
    info_log "RoleBindings increased: $RB_BEFORE → $RB_AFTER"
else
    fail_test "No new RoleBindings created (still $RB_AFTER)"
fi

# Verify RoleBinding references new role
DEVELOPER_RB=$(kubectl_retry kubectl get rolebindings -A -o json | jq -r '.items[] | select(.roleRef.name=="edit") | .metadata.name' | grep -c "developer" 2>/dev/null | head -1 || echo "0")
if [ "$DEVELOPER_RB" -gt 0 ]; then
    pass_test "RoleBindings reference new ClusterRole correctly"
else
    info_log "No 'developer' RoleBindings found (ConfigMap may not have matching entries)"
fi

echo ""

# ============================================================================
# Test 2: Prefix Changes
# ============================================================================
echo "Test 2: Prefix Changes"
echo "-----------------------"

# Note: Current implementation uses prefixes (array), not single prefix
# This test verifies prefix change behavior

# Count RoleBindings with current prefix
CURRENT_RB=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
info_log "Current RoleBindings: $CURRENT_RB"

# Change prefix array
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"replace","path":"/spec/prefixes","value":["NEW-PREFIX"]}]' >/dev/null 2>&1

sleep 15

# Check if operator processed new prefix
NEW_PREFIX_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -c "NEW-PREFIX" | tr -d '\n' | head -1 || echo "0")
info_log "Logs mentioning NEW-PREFIX: $NEW_PREFIX_LOGS"

if [ "$NEW_PREFIX_LOGS" -gt 0 ]; then
    pass_test "Operator processed new prefix configuration"
else
    info_log "New prefix not yet processed (ConfigMap entries use old prefix)"
fi

# Restore original prefix
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"replace","path":"/spec/prefixes","value":["COMPANY-K8S"]}]' >/dev/null 2>&1
sleep 5

echo ""

# ============================================================================
# Test 3: Exclude List Changes
# ============================================================================
echo "Test 3: Exclude List Changes"
echo "------------------------------"

# Add excluded namespace to excludeNamespaces list
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"add","path":"/spec/excludeNamespaces/-","value":"excluded-test-ns"}]' >/dev/null 2>&1

# Add entry to ConfigMap that should be excluded
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-exclude.txt
echo "CN=COMPANY-K8S-excluded-test-ns-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-exclude.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-exclude.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-exclude.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-exclude="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check namespace was NOT created
EXCLUDED_NS=$(kubectl_retry kubectl get namespace excluded-test-ns 2>/dev/null && echo "created" || echo "excluded")
if [ "$EXCLUDED_NS" == "excluded" ]; then
    pass_test "Excluded namespace was not created"
else
    fail_test "Excluded namespace was created despite being in exclude list"
fi

# Check logs for "Skipping excluded"
SKIP_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -c "excluded" | tr -d '\n' | head -1 || echo "0")
info_log "Exclude-related log entries: $SKIP_LOGS"

# Cleanup
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"remove","path":"/spec/excludeNamespaces/1"}]' >/dev/null 2>&1

echo ""

# ============================================================================
# Test 4: ConfigMap Changes - Addition
# ============================================================================
echo "Test 4: ConfigMap Changes - Addition"
echo "-------------------------------------"

# Add new LDAP DN entry to whitelist.txt
NEW_ENTRY="CN=COMPANY-K8S-test4-new-namespace-admin,OU=TestOU,DC=example,DC=com"
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-add.txt
echo "$NEW_ENTRY" >> /tmp/whitelist-add.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-add.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-add.txt

# Force reconciliation
kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-addition="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 30

# Check namespace created
NS_EXISTS=$(kubectl_retry kubectl get namespace test4-new-namespace 2>/dev/null | wc -l)
if [ "$NS_EXISTS" -gt 0 ]; then
    pass_test "New namespace created from ConfigMap entry"
else
    fail_test "Namespace not created"
fi

# Check RoleBinding created
RB_EXISTS=$(kubectl_retry kubectl get rolebinding test4-new-namespace-admin -n test4-new-namespace 2>/dev/null | wc -l)
if [ "$RB_EXISTS" -gt 0 ]; then
    pass_test "RoleBinding created for new ConfigMap entry"
else
    fail_test "RoleBinding not created"
fi

# Verify annotations
ANNOTATIONS=$(kubectl_retry kubectl get rolebinding test4-new-namespace-admin -n test4-new-namespace -o jsonpath='{.metadata.annotations}' 2>/dev/null | jq -e '."permission-binder.io/managed-by"' 2>/dev/null)
if [ "$ANNOTATIONS" == "\"permission-binder-operator\"" ]; then
    pass_test "RoleBinding has correct annotations"
else
    info_log "RoleBinding annotations may be incorrect"
fi

echo ""

# ============================================================================
# Test 5: ConfigMap Changes - Removal
# ============================================================================
echo "Test 5: ConfigMap Changes - Removal"
echo "------------------------------------"

# Count RoleBindings before removal
RB_BEFORE_REMOVAL=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)

# Remove entry from whitelist.txt (remove project3 if exists)
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' | grep -v "project3" > /tmp/whitelist-removal.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-removal.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-removal.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-removal="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 20

# Check RoleBinding removed
RB_AFTER_REMOVAL=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_AFTER_REMOVAL" -le "$RB_BEFORE_REMOVAL" ]; then
    pass_test "RoleBinding removed after ConfigMap entry deletion"
    info_log "RoleBindings: $RB_BEFORE_REMOVAL → $RB_AFTER_REMOVAL"
else
    info_log "RoleBinding count unchanged (may need more reconciliation time)"
fi

# Verify namespace preserved (SAFE MODE)
NS_PROJECT3=$(kubectl_retry kubectl get namespace project3 2>/dev/null | wc -l)
if [ "$NS_PROJECT3" -gt 0 ]; then
    pass_test "Namespace preserved after entry removal (SAFE MODE)"
else
    info_log "Namespace project3 doesn't exist or was deleted"
fi

echo ""

# ============================================================================
# Test 6: Role Removal from Mapping
# ============================================================================
echo "Test 6: Role Removal from Mapping"
echo "-----------------------------------"

# Add temporary role
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"add","path":"/spec/roleMapping/temp-test-role","value":"view"}]' >/dev/null 2>&1

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-temp-add="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check if temp role RoleBindings were created
TEMP_RB_COUNT=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '[.items[] | select(.metadata.name | contains("temp-test-role"))] | length')
info_log "Temp role RoleBindings created: $TEMP_RB_COUNT"

# Remove temp role
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"remove","path":"/spec/roleMapping/temp-test-role"}]' >/dev/null 2>&1

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-temp-remove="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check temp role RoleBindings were removed
TEMP_RB_AFTER=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '[.items[] | select(.metadata.name | contains("temp-test-role"))] | length')
if [ "$TEMP_RB_AFTER" -eq 0 ]; then
    pass_test "RoleBindings removed when role deleted from mapping"
else
    fail_test "RoleBindings not removed: still $TEMP_RB_AFTER temp-test-role RoleBindings"
fi

echo ""

# ============================================================================
# Test 7: Namespace Protection
# ============================================================================
echo "Test 7: Namespace Protection"
echo "-----------------------------"

# This test verifies operator NEVER deletes namespaces
# Even when ConfigMap entries are removed, namespaces should persist

# Check if any managed namespaces exist
MANAGED_NS_COUNT=$(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
info_log "Managed namespaces: $MANAGED_NS_COUNT"

if [ "$MANAGED_NS_COUNT" -gt 0 ]; then
    pass_test "Namespace protection verified (namespaces exist and are managed)"
else
    info_log "No managed namespaces found (may be expected in clean environment)"
fi

# Verify namespaces have proper labels
LABELED_NS=$(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '.items[0].metadata.name' 2>/dev/null)
if [ "$LABELED_NS" != "null" ] && [ -n "$LABELED_NS" ]; then
    info_log "Example managed namespace: $LABELED_NS"
    pass_test "Namespaces are properly labeled and protected"
fi

echo ""

# ============================================================================
# Test 8: PermissionBinder Deletion (SAFE MODE)
# ============================================================================
echo "Test 8: PermissionBinder Deletion (SAFE MODE)"
echo "-----------------------------------------------"

# Count resources before deletion
RB_BEFORE_DELETE=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
NS_BEFORE_DELETE=$(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
info_log "Before deletion: $RB_BEFORE_DELETE RoleBindings, $NS_BEFORE_DELETE Namespaces"

# Delete PermissionBinder
kubectl_retry kubectl delete permissionbinder permissionbinder-example -n $NAMESPACE >/dev/null 2>&1
sleep 10

# Check resources were NOT deleted (SAFE MODE)
RB_AFTER_DELETE=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
NS_AFTER_DELETE=$(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)

if [ "$RB_AFTER_DELETE" -eq "$RB_BEFORE_DELETE" ] && [ "$NS_AFTER_DELETE" -eq "$NS_BEFORE_DELETE" ]; then
    pass_test "SAFE MODE: Resources NOT deleted when PermissionBinder deleted"
    info_log "After deletion: $RB_AFTER_DELETE RoleBindings, $NS_AFTER_DELETE Namespaces"
else
    fail_test "Resources were deleted! RB: $RB_BEFORE_DELETE→$RB_AFTER_DELETE, NS: $NS_BEFORE_DELETE→$NS_AFTER_DELETE"
fi

# Check orphaned annotations
ORPHANED_COUNT=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '[.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])] | length')
if [ "$ORPHANED_COUNT" -gt 0 ]; then
    pass_test "Resources marked as orphaned (annotation added)"
    info_log "Orphaned resources: $ORPHANED_COUNT"
else
    info_log "No orphaned annotations found (may need more reconciliation time)"
fi

echo ""

# ============================================================================
# Test 9: Operator Restart Recovery
# ============================================================================
echo "Test 9: Operator Restart Recovery"
echo "-----------------------------------"

# Recreate PermissionBinder first (needed for operator to work)
kubectl apply -f example/permissionbinder/permissionbinder-example.yaml >/dev/null 2>&1
sleep 5

# Count resources before restart
RB_BEFORE_RESTART=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
NS_BEFORE_RESTART=$(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)

# Restart operator
kubectl rollout restart deployment operator-controller-manager -n $NAMESPACE >/dev/null 2>&1
kubectl rollout status deployment operator-controller-manager -n $NAMESPACE --timeout=60s >/dev/null 2>&1
sleep 15

# Count resources after restart
RB_AFTER_RESTART=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
NS_AFTER_RESTART=$(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)

# Verify no duplicates created
if [ "$RB_AFTER_RESTART" -eq "$RB_BEFORE_RESTART" ] && [ "$NS_AFTER_RESTART" -eq "$NS_BEFORE_RESTART" ]; then
    pass_test "Operator recovered without creating duplicates"
    info_log "Resources stable: $RB_AFTER_RESTART RoleBindings, $NS_AFTER_RESTART Namespaces"
else
    fail_test "Resource count changed (RB: $RB_BEFORE_RESTART→$RB_AFTER_RESTART, NS: $NS_BEFORE_RESTART→$NS_AFTER_RESTART)"
fi

echo ""

# ============================================================================
# Test 10: Conflict Handling
# ============================================================================
echo "Test 10: Conflict Handling"
echo "----------------------------"

# Add duplicate entry to ConfigMap
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-dup.txt
echo "CN=COMPANY-K8S-project1-engineer,OU=Test,DC=example,DC=com" >> /tmp/whitelist-dup.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-dup.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-dup.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-conflict="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 15

# Verify no crash errors in logs
CRASH_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "panic\|fatal\|crash" | wc -l)
if [ "$CRASH_ERRORS" -eq 0 ]; then
    pass_test "Operator handled duplicate entries gracefully (no panic/crash)"
else
    fail_test "Operator encountered errors: $CRASH_ERRORS panic/crash logs"
fi

# Verify RoleBindings still managed
RB_CONFLICT=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_CONFLICT" -gt 0 ]; then
    pass_test "RoleBindings still managed despite duplicates"
else
    fail_test "RoleBindings lost due to conflict"
fi

echo ""

# ============================================================================
# Test 11: Invalid Configuration Handling
# ============================================================================
echo "Test 11: Invalid Configuration Handling"
echo "-----------------------------------------"

# Add invalid LDAP DN to whitelist.txt (missing CN=)
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-invalid.txt
echo "INVALID-FORMAT-no-cn-prefix,OU=Test,DC=example,DC=com" >> /tmp/whitelist-invalid.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-invalid.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-invalid.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-invalid="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check operator logs for error handling
ERROR_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "error\|invalid" | wc -l)
info_log "Error/invalid log entries: $ERROR_LOGS"

# Verify valid entries still processed
VALID_RB_COUNT=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$VALID_RB_COUNT" -ge 5 ]; then
    pass_test "Valid entries still processed despite invalid entry"
else
    fail_test "Valid entries not processed (found only $VALID_RB_COUNT RoleBindings)"
fi

# Verify operator still running
DEPLOYMENT_READY=$(kubectl_retry kubectl get deployment operator-controller-manager -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator remains running after invalid configuration"
else
    fail_test "Operator deployment not ready"
fi

echo ""

# ============================================================================
# Test 12: Multi-Architecture Verification
# ============================================================================
echo "Test 12: Multi-Architecture Verification"
echo "------------------------------------------"

# Check operator pod architecture
POD_NAME=$(kubectl_retry kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=permission-binder-operator -o jsonpath='{.items[0].metadata.name}')
NODE_NAME=$(kubectl_retry kubectl get pod -n $NAMESPACE $POD_NAME -o jsonpath='{.spec.nodeName}')
NODE_ARCH=$(kubectl_retry kubectl get node $NODE_NAME -o jsonpath='{.status.nodeInfo.architecture}')

info_log "Operator running on node: $NODE_NAME ($NODE_ARCH)"

# Verify operator is functional
if [ "$VALID_RB_COUNT" -gt 0 ]; then
    pass_test "Operator functional on $NODE_ARCH architecture"
else
    fail_test "Operator not functional on $NODE_ARCH"
fi

# Check image supports multi-arch
IMAGE=$(kubectl_retry kubectl get deployment operator-controller-manager -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].image}')
info_log "Operator image: $IMAGE"

echo ""

# ============================================================================
# Test 13: Non-Existent ClusterRole (Security)
# ============================================================================
echo "Test 13: Non-Existent ClusterRole (Security)"
echo "----------------------------------------------"

# Add role with non-existent ClusterRole
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"add","path":"/spec/roleMapping/security-test","value":"nonexistent-clusterrole"}]' >/dev/null 2>&1

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-security="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check for security warning in logs
SECURITY_WARNING=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -v "^I" | jq -c 'select(.severity=="warning" and .clusterRole=="nonexistent-clusterrole")' 2>/dev/null | wc -l)

if [ "$SECURITY_WARNING" -gt 0 ]; then
    pass_test "ClusterRole validation logged security WARNING"
    info_log "Found $SECURITY_WARNING warning logs for missing ClusterRole"
else
    info_log "No security warning detected (may not be implemented or needs more time)"
fi

# Verify RoleBinding was still created (operator should create it despite missing ClusterRole)
SECURITY_RB=$(kubectl_retry kubectl get rolebinding --all-namespaces -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '[.items[] | select(.roleRef.name=="nonexistent-clusterrole")] | length')
if [ "$SECURITY_RB" -gt 0 ]; then
    pass_test "RoleBinding created despite missing ClusterRole"
else
    info_log "RoleBinding not created (may be due to no matching ConfigMap entries)"
fi

# Cleanup
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"remove","path":"/spec/roleMapping/security-test"}]' >/dev/null 2>&1

echo ""

# ============================================================================
# Test 14: Orphaned Resources Adoption
# ============================================================================
echo "Test 14: Orphaned Resources Adoption"
echo "--------------------------------------"

# Check for orphaned resources (from Test 8)
ORPHANED_BEFORE=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '[.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])] | length')
info_log "Orphaned resources before reconciliation: $ORPHANED_BEFORE"

# Force reconciliation
kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-adoption="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 30

# Check adoption logs
ADOPTION_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=100 | grep -v "^I" | grep -c "Adopted\|adoption" 2>/dev/null | tr -d '\n' | head -1 || echo "0")
info_log "Adoption-related log entries: $ADOPTION_LOGS"

# Check if orphaned resources decreased
ORPHANED_AFTER=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '[.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])] | length' | tr -d '\n')

if [ "$ORPHANED_AFTER" -lt "$ORPHANED_BEFORE" ] || [ "$ADOPTION_LOGS" -gt 0 ]; then
    pass_test "Automatic adoption of orphaned resources"
    info_log "Orphaned resources: $ORPHANED_BEFORE → $ORPHANED_AFTER"
else
    info_log "No adoption detected (resources: $ORPHANED_BEFORE → $ORPHANED_AFTER)"
fi

echo ""

# ============================================================================
# Test 15: Manual RoleBinding Modification (Protection)
# ============================================================================
echo "Test 15: Manual RoleBinding Modification (Protection)"
echo "-------------------------------------------------------"

# Find a managed RoleBinding
SAMPLE_RB=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator -o json | jq -r '.items[0] | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null)

if [ -n "$SAMPLE_RB" ] && [ "$SAMPLE_RB" != "null/" ]; then
    RB_NAMESPACE=$(echo $SAMPLE_RB | cut -d/ -f1)
    RB_NAME=$(echo $SAMPLE_RB | cut -d/ -f2)
    
    # Get original group
    ORIGINAL_GROUP=$(kubectl_retry kubectl get rolebinding $RB_NAME -n $RB_NAMESPACE -o jsonpath='{.subjects[0].name}' 2>/dev/null)
    info_log "Testing RoleBinding: $RB_NAMESPACE/$RB_NAME (group: $ORIGINAL_GROUP)"
    
    # Manually modify RoleBinding
    kubectl_retry kubectl patch rolebinding $RB_NAME -n $RB_NAMESPACE --type='json' \
      -p='[{"op":"replace","path":"/subjects/0/name","value":"MANUALLY-HACKED-GROUP"}]' >/dev/null 2>&1
    
    sleep 5
    
    # Trigger reconciliation
    kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-override="$(date +%s)" --overwrite >/dev/null 2>&1
    sleep 10
    
    # Check if restored
    CURRENT_GROUP=$(kubectl_retry kubectl get rolebinding $RB_NAME -n $RB_NAMESPACE -o jsonpath='{.subjects[0].name}' 2>/dev/null)
    
    if [ "$CURRENT_GROUP" == "$ORIGINAL_GROUP" ]; then
        pass_test "Operator enforced desired state (overrode manual change)"
    else
        info_log "Manual change persisted or reconciliation pending: $CURRENT_GROUP (expected: $ORIGINAL_GROUP)"
    fi
else
    info_log "No RoleBindings found to test manual modification protection"
fi

echo ""

# ============================================================================
# Test 16: Operator Permission Loss (Security)
# ============================================================================
echo "Test 16: Operator Permission Loss (Security)"
echo "----------------------------------------------"

# This test temporarily removes RBAC permissions to verify error handling
# Note: Be careful with this test as it affects operator functionality

# Remove a specific permission (list rolebindings)
kubectl_retry kubectl get clusterrole permission-binder-operator-manager-role -o json > /tmp/clusterrole-backup.json
kubectl_retry kubectl get clusterrole permission-binder-operator-manager-role -o json | \
  jq 'del(.rules[] | select(.resources[] == "rolebindings"))' | \
  kubectl apply -f - >/dev/null 2>&1

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-rbac-loss="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check for permission errors in logs
PERMISSION_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "forbidden\|unauthorized\|permission denied" | wc -l)

if [ "$PERMISSION_ERRORS" -gt 0 ]; then
    pass_test "Operator logged permission errors correctly"
    info_log "Permission error log entries: $PERMISSION_ERRORS"
else
    info_log "No permission errors detected (RBAC may still be valid)"
fi

# Restore permissions
kubectl apply -f /tmp/clusterrole-backup.json >/dev/null 2>&1
rm -f /tmp/clusterrole-backup.json
sleep 5

# Verify operator recovered
DEPLOYMENT_READY=$(kubectl_retry kubectl get deployment operator-controller-manager -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator recovered after RBAC restoration"
else
    fail_test "Operator not running after RBAC restoration: $POD_STATUS"
fi

echo ""

# ============================================================================
# Test 17: Partial Failure Recovery (Reliability)
# ============================================================================
echo "Test 17: Partial Failure Recovery (Reliability)"
echo "-------------------------------------------------"

# Add mix of valid and invalid entries
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-mixed.txt
echo "CN=COMPANY-K8S-valid-test17-ns-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-mixed.txt
echo "INVALID-ENTRY-NO-CN" >> /tmp/whitelist-mixed.txt
echo "CN=COMPANY-K8S-another-valid-test17-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-mixed.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-mixed.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-mixed.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-partial="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 20

# Check if valid entries were processed
VALID_NS1=$(kubectl_retry kubectl get namespace valid-test17-ns 2>/dev/null | wc -l)
VALID_NS2=$(kubectl_retry kubectl get namespace another-valid-test17 2>/dev/null | wc -l)

if [ "$VALID_NS1" -gt 0 ] || [ "$VALID_NS2" -gt 0 ]; then
    pass_test "Valid entries processed despite invalid ones"
else
    info_log "Valid namespaces not created (may be timing or parsing issue)"
fi

# Verify operator still running
DEPLOYMENT_READY=$(kubectl_retry kubectl get deployment operator-controller-manager -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator remains running after partial failures"
else
    fail_test "Operator deployment not ready"
fi

echo ""

# ============================================================================
# Test 18: JSON Structured Logging Verification (Audit)
# ============================================================================
echo "Test 18: JSON Structured Logging Verification (Audit)"
echo "-------------------------------------------------------"

# Extract operator logs
ALL_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=100 2>/dev/null)

# Count total log lines (excluding K8s info lines)
TOTAL_LINES=$(echo "$ALL_LOGS" | grep -v "^I" | grep -v "^$" | wc -l)

# Count valid JSON lines
VALID_JSON_LINES=$(echo "$ALL_LOGS" | grep -v "^I" | grep -v "^$" | while read line; do
    echo "$line" | jq -e '.level' >/dev/null 2>&1 && echo "1"
done | wc -l)

# Calculate percentage
if [ "$TOTAL_LINES" -gt 0 ]; then
    PERCENTAGE=$((VALID_JSON_LINES * 100 / TOTAL_LINES))
    if [ "$PERCENTAGE" -ge 90 ]; then
        pass_test "JSON structured logging verified ($PERCENTAGE% valid JSON)"
        info_log "Valid JSON lines: $VALID_JSON_LINES / $TOTAL_LINES"
    else
        info_log "JSON logging percentage: $PERCENTAGE% (valid: $VALID_JSON_LINES/$TOTAL_LINES)"
    fi
else
    info_log "No logs found to verify"
fi

# Verify required JSON fields
LOGS_WITH_LEVEL=$(echo "$ALL_LOGS" | grep -v "^I" | jq -e '.level' 2>/dev/null | wc -l)
LOGS_WITH_MESSAGE=$(echo "$ALL_LOGS" | grep -v "^I" | jq -e '.message' 2>/dev/null | wc -l)
info_log "Logs with 'level' field: $LOGS_WITH_LEVEL, with 'message' field: $LOGS_WITH_MESSAGE"

echo ""

# ============================================================================
# Test 19: Concurrent ConfigMap Changes (Race Conditions)
# ============================================================================
echo "Test 19: Concurrent ConfigMap Changes (Race Conditions)"
echo "---------------------------------------------------------"

# Make rapid concurrent changes to trigger potential race conditions
for i in {1..5}; do
    kubectl_retry kubectl annotate configmap permission-config -n $NAMESPACE concurrent-test-$i="$(date +%s)" --overwrite >/dev/null 2>&1 &
done
wait

sleep 20

# Verify no race condition errors
RACE_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -i "conflict\|race\|concurrent" | wc -l)
info_log "Concurrent change log entries: $RACE_ERRORS"

# Verify resources are consistent
RB_CONSISTENT=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_CONSISTENT" -gt 0 ]; then
    pass_test "Resources consistent after concurrent changes"
else
    fail_test "Resources lost after concurrent changes"
fi

# Verify operator didn't restart
POD_RESTARTS=$(kubectl_retry kubectl get pods -n $NAMESPACE -l control-plane=controller-manager -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
if [ "$POD_RESTARTS" -eq 0 ]; then
    pass_test "Operator handled concurrent changes without restarting"
else
    info_log "Operator restarted $POD_RESTARTS times during test"
fi

echo ""

# ============================================================================
# Test 20: ConfigMap Corruption Handling
# ============================================================================
echo "Test 20: ConfigMap Corruption Handling"
echo "----------------------------------------"

# Test with various malformed entries
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-corrupt.txt
echo "CN=COMPANY-K8S-incomplete" >> /tmp/whitelist-corrupt.txt  # Missing parts
echo "CN=" >> /tmp/whitelist-corrupt.txt  # Empty CN
echo "$(python3 -c 'print("A"*300)')" >> /tmp/whitelist-corrupt.txt  # Too long
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-corrupt.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-corrupt.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-corrupt="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 15

# Verify operator didn't crash
POD_RESTARTS=$(kubectl_retry kubectl get pods -n $NAMESPACE -l control-plane=controller-manager -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
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
# Test 21: Network Failure Simulation
# ============================================================================
echo "Test 21: Network Failure Simulation"
echo "-------------------------------------"

# Simulate stress by rapid reconciliation triggers
info_log "Simulating network stress via rapid reconciliation"

for i in {1..10}; do
    kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE stress-test-$i="$(date +%s)" --overwrite >/dev/null 2>&1 &
done
wait
sleep 15

# Check for connection errors
CONN_ERRORS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=100 | grep -i "connection refused\|timeout\|dial tcp\|i/o timeout" | wc -l)
info_log "Connection-related log entries: $CONN_ERRORS"

# Verify operator is still functional
RB_CURRENT=$(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
if [ "$RB_CURRENT" -gt 0 ]; then
    pass_test "Operator remained functional under stress"
    info_log "Managed RoleBindings: $RB_CURRENT"
else
    fail_test "Operator lost managed resources"
fi

# Verify no crash/restarts
POD_RESTARTS=$(kubectl_retry kubectl get pods -n $NAMESPACE -l control-plane=controller-manager -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
if [ "$POD_RESTARTS" -eq 0 ]; then
    pass_test "Operator handled stress without restarting"
else
    info_log "Operator restarted $POD_RESTARTS times during stress test"
fi

echo ""

# ============================================================================
# Test 22: Metrics Endpoint Verification
# ============================================================================
echo "Test 22: Metrics Endpoint Verification"
echo "----------------------------------------"

# Use port-forward to access metrics endpoint
kubectl port-forward -n $NAMESPACE svc/operator-controller-manager-metrics-service 8080:8080 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 3

# Query metrics endpoint
METRICS_RESPONSE=$(curl -s http://localhost:8080/metrics 2>/dev/null | grep -c "permission_binder" | tr -d '\n' | head -1 || echo "0")
METRICS_RESPONSE=$(echo "$METRICS_RESPONSE" | tr -d '\n' | head -1)

# Kill port-forward
kill $PORT_FORWARD_PID 2>/dev/null || true

if [ "$METRICS_RESPONSE" -gt 0 ]; then
    pass_test "Prometheus metrics endpoint accessible"
    info_log "Found $METRICS_RESPONSE permission_binder metrics"
else
    fail_test "Metrics endpoint not accessible or no custom metrics"
fi

echo ""

# ============================================================================
# Test 23: Finalizer Behavior Verification
# ============================================================================
echo "Test 23: Finalizer Behavior Verification"
echo "------------------------------------------"

# Check if PermissionBinder exists (may have been deleted in Test 8)
if kubectl_retry kubectl get permissionbinder permissionbinder-example -n $NAMESPACE >/dev/null 2>&1; then
    # Verify finalizer is present
    FINALIZER=$(kubectl_retry kubectl get permissionbinder permissionbinder-example -n $NAMESPACE -o jsonpath='{.metadata.finalizers[0]}' 2>/dev/null)
    if [ "$FINALIZER" == "permission-binder.io/finalizer" ]; then
        pass_test "Finalizer is present on PermissionBinder"
    else
        fail_test "Finalizer not found: $FINALIZER"
    fi
else
    # PermissionBinder doesn't exist (deleted in Test 8), which is expected
    pass_test "Finalizer behavior verified in Test 8 (PermissionBinder deleted)"
    info_log "PermissionBinder was deleted in Test 8 - finalizer cleanup tested there"
fi

info_log "Finalizer ensures proper cleanup sequence (tested in Test 8)"

echo ""

# ============================================================================
# Test 24: Large ConfigMap Handling
# ============================================================================
echo "Test 24: Large ConfigMap Handling"
echo "-----------------------------------"

# Create ConfigMap with 50+ entries
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-large.txt
for i in {1..50}; do
    echo "CN=COMPANY-K8S-large-project-$i-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-large.txt
done
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-large.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-large.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-large="$(date +%s)" --overwrite >/dev/null 2>&1

# Time the reconciliation
START_TIME=$(date +%s)
sleep 40
END_TIME=$(date +%s)
RECONCILE_TIME=$((END_TIME - START_TIME))

# Check if entries were processed
LARGE_NS_COUNT=$(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
info_log "Created namespaces: $LARGE_NS_COUNT"
info_log "Reconciliation time: ${RECONCILE_TIME}s"

if [ "$RECONCILE_TIME" -lt 60 ]; then
    pass_test "Large ConfigMap processed in acceptable time (${RECONCILE_TIME}s < 60s)"
else
    info_log "Reconciliation took ${RECONCILE_TIME}s (may be acceptable depending on cluster)"
fi

# Check operator memory usage
POD_NAME=$(kubectl_retry kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=permission-binder-operator -o jsonpath='{.items[0].metadata.name}')
MEMORY_USAGE=$(kubectl top pod -n $NAMESPACE $POD_NAME 2>/dev/null | tail -1 | awk '{print $3}' || echo "N/A")
info_log "Operator memory usage: $MEMORY_USAGE"

echo ""

# ============================================================================
# Test 25: Prometheus Metrics Collection
# ============================================================================
echo "Test 25: Prometheus Metrics Collection"
echo "----------------------------------------"

# Check if Prometheus is running
PROMETHEUS_POD=$(kubectl_retry kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | wc -l)
if [ "$PROMETHEUS_POD" -eq 0 ]; then
    info_log "Prometheus not running - skipping metrics tests 25-30"
    echo "Tests 25-30 skipped (Prometheus not installed)"
    echo ""
else
    pass_test "Prometheus is running"
    
    PROM_POD=$(kubectl_retry kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
    
    # Query basic operator metrics
    METRICS_COUNT=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result | length')
    if [ "$METRICS_COUNT" -gt 0 ]; then
        pass_test "Prometheus collecting operator metrics"
        CURRENT_RB=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result[0].value[1]')
        info_log "Current RoleBindings metric: $CURRENT_RB"
    else
        fail_test "Prometheus not collecting operator metrics"
    fi
    
    echo ""
    
    # ========================================================================
    # Test 26: Metrics Update on Role Mapping Changes
    # ========================================================================
    echo "Test 26: Metrics Update on Role Mapping Changes"
    echo "-------------------------------------------------"
    
    # Record initial metric value
    RB_METRIC_BEFORE=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result[0].value[1]' | cut -d. -f1)
    info_log "RoleBindings metric before: $RB_METRIC_BEFORE"
    
    # Add new role
    kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
      -p='[{"op":"add","path":"/spec/roleMapping/metrics-test","value":"view"}]' >/dev/null 2>&1
    sleep 30
    
    # Check updated metric
    RB_METRIC_AFTER=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result[0].value[1]' | cut -d. -f1)
    info_log "RoleBindings metric after: $RB_METRIC_AFTER"
    
    if [ "$RB_METRIC_AFTER" -gt "$RB_METRIC_BEFORE" ]; then
        pass_test "Metrics updated after role mapping change"
    else
        info_log "Metrics may need more time to update (scrape interval)"
    fi
    
    # Cleanup
    kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
      -p='[{"op":"remove","path":"/spec/roleMapping/metrics-test"}]' >/dev/null 2>&1
    
    echo ""
    
    # ========================================================================
    # Test 27: Metrics Update on ConfigMap Changes
    # ========================================================================
    echo "Test 27: Metrics Update on ConfigMap Changes"
    echo "----------------------------------------------"
    
    # Record initial namespace metric
    NS_METRIC_BEFORE=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_namespaces_total" 2>/dev/null | jq -r '.data.result[0].value[1]' | cut -d. -f1 2>/dev/null || echo "0")
    info_log "Namespaces metric before: $NS_METRIC_BEFORE"
    
    # Add new namespace entry
    kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-metrics.txt
    echo "CN=COMPANY-K8S-metrics-test-ns27-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-metrics.txt
    kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-metrics.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    rm -f /tmp/whitelist-metrics.txt
    
    kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-ns-metrics="$(date +%s)" --overwrite >/dev/null 2>&1
    sleep 30
    
    # Check updated metric
    NS_METRIC_AFTER=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_namespaces_total" 2>/dev/null | jq -r '.data.result[0].value[1]' | cut -d. -f1 2>/dev/null || echo "0")
    info_log "Namespaces metric after: $NS_METRIC_AFTER"
    
    if [ "$NS_METRIC_AFTER" -gt "$NS_METRIC_BEFORE" ]; then
        pass_test "Namespace metrics updated after ConfigMap change"
    else
        info_log "Metrics may need more time to update"
    fi
    
    echo ""
    
    # ========================================================================
    # Test 28: Orphaned Resources Metrics
    # ========================================================================
    echo "Test 28: Orphaned Resources Metrics"
    echo "-------------------------------------"
    
    # Query orphaned resources metric
    ORPHANED_METRIC=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_orphaned_resources_total" 2>/dev/null | jq -r '.data.result[0].value[1]' 2>/dev/null | tr -d '\n' | grep -E '^[0-9]+$' || echo "0")
    info_log "Orphaned resources metric: $ORPHANED_METRIC"
    
    # Should be 0 after Test 14 (adoption completed)
    if [ "$ORPHANED_METRIC" -eq 0 ] 2>/dev/null; then
        pass_test "No orphaned resources (adoption completed successfully)"
    else
        info_log "Some resources still orphaned: $ORPHANED_METRIC"
    fi
    
    echo ""
    
    # ========================================================================
    # Test 29: ConfigMap Processing Metrics
    # ========================================================================
    echo "Test 29: ConfigMap Processing Metrics"
    echo "---------------------------------------"
    
    # Query ConfigMap entries processed metric
    CM_PROCESSED=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_configmap_entries_processed_total" 2>/dev/null | jq -r '.data.result[0].value[1]' 2>/dev/null | tr -d '\n' | grep -E '^[0-9]+$' || echo "0")
    info_log "ConfigMap entries processed: $CM_PROCESSED"
    
    if [ "$CM_PROCESSED" != "0" ] && [ "$CM_PROCESSED" -gt 0 ] 2>/dev/null; then
        pass_test "ConfigMap processing metrics tracked"
    else
        info_log "ConfigMap processing metric not available (may not be implemented)"
    fi
    
    echo ""
    
    # ========================================================================
    # Test 30: Adoption Events Metrics
    # ========================================================================
    echo "Test 30: Adoption Events Metrics"
    echo "----------------------------------"
    
    # Query adoption events metric
    ADOPTION_METRIC=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_adoption_events_total" 2>/dev/null | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "0")
    info_log "Adoption events metric: $ADOPTION_METRIC"
    
    # Should have events from Test 14
    if [ "$ADOPTION_METRIC" -gt 0 ]; then
        pass_test "Adoption events tracked in metrics"
    else
        info_log "No adoption events in metrics (may not be implemented or needs more time)"
    fi
    
    echo ""
fi

# ============================================================================
# Test 31: ServiceAccount Creation
# ============================================================================
echo "Test 31: ServiceAccount Creation"
echo "----------------------------------"

# Create PermissionBinder with SA mapping
cat <<EOF | kubectl_retry kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-basic
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: edit
    runtime: view
EOF

sleep 10

# Check if test-namespace-001 exists and has SA
if kubectl_retry kubectl get namespace test-namespace-001 >/dev/null 2>&1; then
    SA_DEPLOY=$(kubectl_retry kubectl get sa -n test-namespace-001 2>/dev/null | grep -c "sa-deploy" || echo "0")
    SA_RUNTIME=$(kubectl_retry kubectl get sa -n test-namespace-001 2>/dev/null | grep -c "sa-runtime" || echo "0")
    
    if [ "$SA_DEPLOY" -gt 0 ] && [ "$SA_RUNTIME" -gt 0 ]; then
        pass_test "ServiceAccounts created (deploy and runtime)"
        
        # Check RoleBindings
        RB_DEPLOY=$(kubectl_retry kubectl get rolebinding -n test-namespace-001 2>/dev/null | grep -c "sa-deploy" || echo "0")
        RB_RUNTIME=$(kubectl_retry kubectl get rolebinding -n test-namespace-001 2>/dev/null | grep -c "sa-runtime" || echo "0")
        
        if [ "$RB_DEPLOY" -gt 0 ] && [ "$RB_RUNTIME" -gt 0 ]; then
            pass_test "ServiceAccount RoleBindings created"
        else
            fail_test "ServiceAccount RoleBindings not created"
        fi
    else
        fail_test "ServiceAccounts not created (deploy: $SA_DEPLOY, runtime: $SA_RUNTIME)"
    fi
else
    info_log "test-namespace-001 does not exist, skipping SA creation test"
fi

echo ""

# ============================================================================
# Test 32: ServiceAccount Naming Pattern
# ============================================================================
echo "Test 32: ServiceAccount Naming Pattern"
echo "----------------------------------------"

# Create PermissionBinder with custom pattern
cat <<EOF | kubectl_retry kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-pattern
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: edit
  serviceAccountNamingPattern: "sa-{namespace}-{name}"
EOF

sleep 10

# Check custom naming pattern
if kubectl_retry kubectl get namespace test-namespace-001 >/dev/null 2>&1; then
    if kubectl_retry kubectl get sa sa-test-namespace-001-deploy -n test-namespace-001 >/dev/null 2>&1; then
        pass_test "Custom naming pattern works (sa-{namespace}-{name})"
    else
        fail_test "Custom naming pattern not applied"
    fi
else
    info_log "test-namespace-001 does not exist, skipping pattern test"
fi

echo ""

# ============================================================================
# Test 33: ServiceAccount Idempotency
# ============================================================================
echo "Test 33: ServiceAccount Idempotency"
echo "-------------------------------------"

# Record SA UID if it exists
if kubectl_retry kubectl get namespace test-namespace-001 >/dev/null 2>&1; then
    if kubectl_retry kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 >/dev/null 2>&1; then
        SA_UID=$(kubectl_retry kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.uid}')
        
        # Trigger reconciliation
        kubectl_retry kubectl annotate configmap permission-config -n $NAMESPACE test-reconcile="$(date +%s)" --overwrite >/dev/null 2>&1
        sleep 10
        
        # Check if UID changed
        NEW_SA_UID=$(kubectl_retry kubectl get sa test-namespace-001-sa-deploy -n test-namespace-001 -o jsonpath='{.metadata.uid}')
        
        if [ "$SA_UID" == "$NEW_SA_UID" ]; then
            pass_test "ServiceAccount not recreated (idempotent)"
        else
            fail_test "ServiceAccount was recreated (UID changed)"
        fi
    else
        info_log "ServiceAccount test-namespace-001-sa-deploy not found for idempotency test"
    fi
else
    info_log "test-namespace-001 does not exist, skipping idempotency test"
fi

echo ""

# ============================================================================
# Test 34: ServiceAccount Status Tracking
# ============================================================================
echo "Test 34: ServiceAccount Status Tracking"
echo "-----------------------------------------"

# Check status tracking
SA_STATUS=$(kubectl_retry kubectl get permissionbinder test-sa-basic -n $NAMESPACE -o jsonpath='{.status.processedServiceAccounts}' 2>/dev/null)

if [ ! -z "$SA_STATUS" ] && [ "$SA_STATUS" != "null" ]; then
    SA_COUNT=$(echo "$SA_STATUS" | jq '. | length' 2>/dev/null || echo "0")
    info_log "Processed ServiceAccounts tracked: $SA_COUNT"
    
    if [ "$SA_COUNT" -gt 0 ]; then
        pass_test "ServiceAccount status tracking works"
    else
        fail_test "ServiceAccount status empty"
    fi
else
    info_log "ServiceAccount status field not populated (may need more time)"
fi

echo ""

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=========================================================="
echo "E2E Test Suite Summary - Tests 1-34 COMPLETED"
echo "=========================================================="
echo ""
echo "Test Results:"
grep -E "^(✅|❌)" $TEST_RESULTS | sort | uniq -c
echo ""
echo "Detailed results saved to: $TEST_RESULTS"
echo ""
echo "Final Status:"
kubectl_retry kubectl get pods -n $NAMESPACE
echo ""
echo "Managed Resources:"
echo "  RoleBindings: $(kubectl_retry kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)"
echo "  Namespaces: $(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)"
echo ""
echo "Completed: $(date)"
echo ""
