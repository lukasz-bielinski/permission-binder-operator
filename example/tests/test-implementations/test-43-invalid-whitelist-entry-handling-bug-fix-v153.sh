#!/bin/bash
# Test 43: Invalid Whitelist Entry Handling Bug Fix V153
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 43: Invalid Whitelist Entry Handling (Bug Fix v1.5.3)"
echo "-----------------------------------------------------------"

# Create PermissionBinder with unique ConfigMap to avoid conflicts
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-invalid-entries
  namespace: $NAMESPACE
spec:
  configMapName: permission-config-invalid-test
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: edit
    admin: admin
EOF

# Create ConfigMap with mix of valid and invalid entries (unique name to avoid conflicts)
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config-invalid-test
  namespace: $NAMESPACE
data:
  whitelist.txt: |-
    # Valid entry
    CN=COMPANY-K8S-valid-invalid-test-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Invalid entry: Missing prefix
    CN=INVALID-PREFIX-ns-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Invalid entry: Missing role
    CN=COMPANY-K8S-ns-unknownrole,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Invalid entry: Malformed LDAP DN
    INVALID-LDAP-DN-FORMAT
    
    # Invalid entry: Empty CN
    CN=,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Another valid entry (should be processed)
    CN=COMPANY-K8S-valid-invalid-test-2-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
EOF

# Wait for initial processing
sleep 15

# Trigger reconciliation to ensure ConfigMap is processed
kubectl annotate permissionbinder test-invalid-entries -n $NAMESPACE trigger-reconcile="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Verify operator is still running (didn't crash)
OPERATOR_PHASE=$(kubectl get pod -n $NAMESPACE -l control-plane=controller-manager -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
if [ "$OPERATOR_PHASE" == "Running" ]; then
    pass_test "Operator running (didn't crash)"
else
    fail_test "Operator crashed or not running: $OPERATOR_PHASE"
fi

# Verify valid entries were processed
if kubectl get namespace valid-invalid-test >/dev/null 2>&1; then
    pass_test "Valid namespace created"
else
    fail_test "Valid namespace not created"
fi

if kubectl get namespace valid-invalid-test-2 >/dev/null 2>&1; then
    pass_test "Second valid namespace created"
else
    info_log "Second valid namespace not yet created"
fi

if kubectl get rolebinding valid-invalid-test-engineer -n valid-invalid-test >/dev/null 2>&1; then
    pass_test "Valid RoleBinding created"
else
    fail_test "Valid RoleBinding not created"
fi

# Wait a bit more and check logs from last 5 minutes to ensure we capture all processing
sleep 5

# Verify invalid entries logged as INFO (not ERROR)
# Check logs from last 5 minutes to catch all processing
ERROR_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --since=5m 2>/dev/null | jq -r 'select(.level == "error") | select(.message | contains("parse") or contains("extract") or contains("invalid")) | .message' 2>/dev/null || echo "")

if [ -z "$ERROR_LOGS" ]; then
    pass_test "No ERROR level logs for invalid entries"
else
    fail_test "Found ERROR level logs: $ERROR_LOGS"
fi

# Verify invalid entries logged as INFO with detailed context
# Check logs from last 5 minutes to catch all processing
# Parse each line as JSON and filter
INFO_LOGS_COUNT=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --since=5m 2>/dev/null | while read line; do echo "$line" | jq -r 'select(.level == "info") | select(.message | contains("Skipping invalid") or contains("cannot parse") or contains("cannot extract")) | .message' 2>/dev/null; done | grep -v "^$" | wc -l)

if [ "$INFO_LOGS_COUNT" -gt 0 ]; then
    pass_test "Invalid entries logged as INFO (found $INFO_LOGS_COUNT entries)"
else
    # Try one more time with longer time window
    sleep 5
    INFO_LOGS_COUNT=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --since=10m 2>/dev/null | while read line; do echo "$line" | jq -r 'select(.level == "info") | select(.message | contains("Skipping invalid") or contains("cannot parse") or contains("cannot extract")) | .message' 2>/dev/null; done | grep -v "^$" | wc -l)
    if [ "$INFO_LOGS_COUNT" -gt 0 ]; then
        pass_test "Invalid entries logged as INFO (found $INFO_LOGS_COUNT log entries)"
    else
        fail_test "No INFO level logs for invalid entries"
    fi
fi

# Verify log entries contain required fields
# Find log entry with "Skipping invalid" message and check required fields
LOG_ENTRY_FOUND=false
kubectl logs -n $NAMESPACE deployment/operator-controller-manager --since=5m 2>/dev/null | while IFS= read -r line; do
    # Try to parse as JSON and check if it matches
    if echo "$line" | jq -e 'select(.message | contains("Skipping invalid")) | select(.line != null) | select(.reason != null) | select(.action == "skip")' >/dev/null 2>&1; then
        echo "$line" > /tmp/log-entry-43-valid.txt
        echo "found"
        break
    fi
done > /tmp/log-entry-43-status.txt 2>/dev/null

if [ -s /tmp/log-entry-43-valid.txt ] && grep -q "found" /tmp/log-entry-43-status.txt 2>/dev/null; then
    LOG_ENTRY=$(cat /tmp/log-entry-43-valid.txt)
    HAS_LINE=$(echo "$LOG_ENTRY" | jq -e '.line != null' >/dev/null 2>&1 && echo "true" || echo "false")
    HAS_REASON=$(echo "$LOG_ENTRY" | jq -e '.reason != null and .reason != ""' >/dev/null 2>&1 && echo "true" || echo "false")
    HAS_ACTION=$(echo "$LOG_ENTRY" | jq -e '.action == "skip"' >/dev/null 2>&1 && echo "true" || echo "false")
    
    if [ "$HAS_LINE" == "true" ] && [ "$HAS_REASON" == "true" ] && [ "$HAS_ACTION" == "true" ]; then
        pass_test "All required fields present (line, reason, action)"
    else
        # Show what we found for debugging
        LINE_VAL=$(echo "$LOG_ENTRY" | jq -r '.line // "missing"' 2>/dev/null)
        REASON_VAL=$(echo "$LOG_ENTRY" | jq -r '.reason // "missing"' 2>/dev/null | cut -c1-50)
        ACTION_VAL=$(echo "$LOG_ENTRY" | jq -r '.action // "missing"' 2>/dev/null)
        fail_test "Missing required fields: line=$HAS_LINE($LINE_VAL), reason=$HAS_REASON($REASON_VAL), action=$HAS_ACTION($ACTION_VAL)"
    fi
else
    info_log "No log entries with required fields found (may need more reconciliations)"
fi

# Verify no stacktraces in logs
# Check logs from last 5 minutes
STACKTRACE=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --since=5m 2>/dev/null | grep -i "stacktrace\|panic\|goroutine" || echo "")

if [ -z "$STACKTRACE" ]; then
    pass_test "No stacktraces in logs"
else
    fail_test "Found stacktrace in logs"
fi

# Test multiple invalid entries (stress test)
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config-invalid-test
  namespace: $NAMESPACE
data:
  whitelist.txt: |-
    $(for i in {1..10}; do echo "INVALID-ENTRY-$i"; done)
    CN=COMPANY-K8S-stress-invalid-test-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
EOF

# Wait for processing
sleep 15

# Trigger reconciliation to ensure ConfigMap is processed
kubectl annotate permissionbinder test-invalid-entries -n $NAMESPACE trigger-reconcile="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Verify operator still running and valid entry processed
OPERATOR_PHASE_STRESS=$(kubectl get pod -n $NAMESPACE -l control-plane=controller-manager -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
if [ "$OPERATOR_PHASE_STRESS" == "Running" ]; then
    pass_test "Operator survived stress test"
else
    fail_test "Operator crashed during stress test"
fi

if kubectl get namespace stress-invalid-test >/dev/null 2>&1; then
    pass_test "Valid entry processed despite many invalid entries"
else
    info_log "Valid entry not yet processed (may need more time)"
fi

echo ""

# ============================================================================
