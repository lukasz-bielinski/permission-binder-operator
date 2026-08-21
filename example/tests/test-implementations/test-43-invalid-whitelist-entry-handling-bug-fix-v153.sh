#!/bin/bash
# Test 43: Invalid Whitelist Entry Handling Bug Fix V153
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# Test namespaces carry the per-instance prefix (empty in legacy mode).
# CR name (test-invalid-entries) and ConfigMap name are NOT prefixed.
VALID_NS="${TEST_NS_PREFIX}valid-invalid-test"
VALID_NS_2="${TEST_NS_PREFIX}valid-invalid-test-2"
STRESS_NS="${TEST_NS_PREFIX}stress-invalid-test"

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
    CN=COMPANY-K8S-${VALID_NS}-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Invalid entry: Missing prefix
    CN=INVALID-PREFIX-ns-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Invalid entry: Missing role
    CN=COMPANY-K8S-ns-unknownrole,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Invalid entry: Malformed LDAP DN
    INVALID-LDAP-DN-FORMAT
    
    # Invalid entry: Empty CN
    CN=,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Another valid entry (should be processed)
    CN=COMPANY-K8S-${VALID_NS_2}-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
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
if kubectl get namespace "$VALID_NS" >/dev/null 2>&1; then
    pass_test "Valid namespace created"
else
    fail_test "Valid namespace not created"
fi

if kubectl get namespace "$VALID_NS_2" >/dev/null 2>&1; then
    pass_test "Second valid namespace created"
else
    info_log "Second valid namespace not yet created"
fi

if kubectl get rolebinding "${VALID_NS}-engineer" -n "$VALID_NS" >/dev/null 2>&1; then
    pass_test "Valid RoleBinding created"
else
    fail_test "Valid RoleBinding not created"
fi

# Wait a bit more and check logs from last 5 minutes to ensure we capture all processing
sleep 5

# Verify invalid entries logged as INFO (not ERROR)
# Check logs from last 5 minutes to catch all processing.
# Scoped to THIS test's CR/ConfigMap: this operator reconciles ALL
# PermissionBinders (until WATCH_NAMESPACE is used), so error entries caused
# by a sibling instance's invalid-config tests must not trip this assertion.
# fromjson? skips non-JSON lines instead of aborting the whole pipe.
ERROR_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --since=5m 2>/dev/null | jq -R -r --arg pb "test-invalid-entries" --arg cm "permission-config-invalid-test" 'fromjson? | select(.level == "error") | select(.message | contains("parse") or contains("extract") or contains("invalid")) | select(tostring | contains($pb) or contains($cm)) | .message' 2>/dev/null || echo "")

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
# Scratch files live under $RUN_DIR (per-instance) and are removed up front so
# a stale file from a previous run can never satisfy the check.
LOG_ENTRY_VALID="${RUN_DIR:-/tmp}/log-entry-43-valid.txt"
LOG_ENTRY_STATUS="${RUN_DIR:-/tmp}/log-entry-43-status.txt"
rm -f "$LOG_ENTRY_VALID" "$LOG_ENTRY_STATUS"
LOG_ENTRY_FOUND=false
kubectl logs -n $NAMESPACE deployment/operator-controller-manager --since=5m 2>/dev/null | while IFS= read -r line; do
    # Try to parse as JSON and check if it matches
    if echo "$line" | jq -e 'select(.message | contains("Skipping invalid")) | select(.line != null) | select(.reason != null) | select(.action == "skip")' >/dev/null 2>&1; then
        echo "$line" > "$LOG_ENTRY_VALID"
        echo "found"
        break
    fi
done > "$LOG_ENTRY_STATUS" 2>/dev/null

if [ -s "$LOG_ENTRY_VALID" ] && grep -q "found" "$LOG_ENTRY_STATUS" 2>/dev/null; then
    LOG_ENTRY=$(cat "$LOG_ENTRY_VALID")
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

# Verify no REAL crash evidence in logs.
# A plain grep for stacktrace|panic|goroutine false-fails: zap attaches a
# literal "stacktrace" JSON field to every error-level entry, including
# routine recoverable ones (e.g. status-update conflicts caused by a sibling
# instance reconciling the same CRs). Real crashes show up as:
#  - plain-text Go runtime dump lines (panic: ... / goroutine N [state]:), or
#  - error entries WITH a stacktrace that reference THIS test's CR/ConfigMap.
LOGS_43="${RUN_DIR:-/tmp}/operator-logs-43.txt"
kubectl logs -n $NAMESPACE deployment/operator-controller-manager --since=5m >"$LOGS_43" 2>/dev/null
CRASH_DUMP=$(grep -E '^panic:|^goroutine [0-9]+ \[' "$LOGS_43" 2>/dev/null || echo "")
SCOPED_STACKTRACE=$(jq -R -r --arg pb "test-invalid-entries" --arg cm "permission-config-invalid-test" 'fromjson? | select(.level == "error") | select(.stacktrace != null and .stacktrace != "") | select(tostring | contains($pb) or contains($cm)) | .message' "$LOGS_43" 2>/dev/null || echo "")
STACKTRACE="${CRASH_DUMP}${SCOPED_STACKTRACE}"

if [ -z "$STACKTRACE" ]; then
    pass_test "No stacktraces in logs"
else
    fail_test "Found stacktrace in logs: $(echo "$STACKTRACE" | head -2)"
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
    CN=COMPANY-K8S-${STRESS_NS}-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
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

if kubectl get namespace "$STRESS_NS" >/dev/null 2>&1; then
    pass_test "Valid entry processed despite many invalid entries"
else
    info_log "Valid entry not yet processed (may need more time)"
fi

echo ""

# ============================================================================
