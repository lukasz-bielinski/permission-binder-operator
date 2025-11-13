### Test 43: Invalid Whitelist Entry Handling (Bug Fix v1.5.3)

**Objective**: Verify operator gracefully handles invalid whitelist entries without crashing or spamming error logs

**Background**:
Previous bug (fixed in v1.5.3): Invalid whitelist entries were logged as `logger.Error()` with stacktraces, causing noise in logs and potential operator instability. The fix changed error logging to `logger.Info()` with detailed context, allowing operator to skip invalid entries and continue processing.

**Setup**:
```bash
# Create PermissionBinder
kubectl apply -f - <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-invalid-entries
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: edit
    admin: admin
EOF

# Create ConfigMap with mix of valid and invalid entries
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |-
    # Valid entry
    CN=COMPANY-K8S-valid-ns-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Invalid entry: Missing prefix
    CN=INVALID-PREFIX-ns-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Invalid entry: Missing role
    CN=COMPANY-K8S-ns-unknownrole,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Invalid entry: Malformed LDAP DN
    INVALID-LDAP-DN-FORMAT
    
    # Invalid entry: Empty CN
    CN=,OU=Kubernetes,OU=Platform,DC=example,DC=com
    
    # Another valid entry (should be processed)
    CN=COMPANY-K8S-valid-ns-2-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
EOF

sleep 10
```

**Execution**:
```bash
# Step 1: Verify operator is still running (didn't crash)
kubectl get pod -n permissions-binder-operator -l control-plane=controller-manager -o jsonpath='{.items[0].status.phase}' | grep "Running" && echo "PASS: Operator running" || echo "FAIL: Operator crashed or not running"

# Step 2: Verify valid entries were processed
kubectl get namespace valid-ns && echo "PASS: Valid namespace created" || echo "FAIL: Valid namespace not created"
kubectl get namespace valid-ns-2 && echo "PASS: Second valid namespace created" || echo "FAIL: Second valid namespace not created"

kubectl get rolebinding valid-ns-engineer -n valid-ns && echo "PASS: Valid RoleBinding created" || echo "FAIL: Valid RoleBinding not created"
kubectl get rolebinding valid-ns-2-admin -n valid-ns-2 && echo "PASS: Second valid RoleBinding created" || echo "FAIL: Second valid RoleBinding not created"

# Step 3: Verify invalid entries logged as INFO (not ERROR)
ERROR_LOGS=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=200 | jq -r 'select(.level == "error") | select(.message | contains("parse") or contains("extract") or contains("invalid")) | .message')

if [ -z "$ERROR_LOGS" ]; then
  echo "PASS: No ERROR level logs for invalid entries"
else
  echo "FAIL: Found ERROR level logs: $ERROR_LOGS"
fi

# Step 4: Verify invalid entries logged as INFO with detailed context
INFO_LOGS=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=200 | jq -r 'select(.level == "info") | select(.message | contains("Skipping invalid") or contains("cannot parse") or contains("cannot extract"))')

if [ -n "$INFO_LOGS" ]; then
  echo "PASS: Invalid entries logged as INFO"
  echo "INFO logs found:"
  echo "$INFO_LOGS" | head -5
else
  echo "FAIL: No INFO level logs for invalid entries"
fi

# Step 5: Verify log entries contain required fields
LOG_ENTRY=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=200 | jq -r 'select(.message | contains("Skipping invalid")) | select(.line != null) | .' | head -1)

if [ -n "$LOG_ENTRY" ]; then
  echo "PASS: Log entry contains required fields"
  echo "Sample log entry:"
  echo "$LOG_ENTRY" | jq '{line, cn, reason, action}'
  
  # Verify specific fields
  HAS_LINE=$(echo "$LOG_ENTRY" | jq -r '.line != null')
  HAS_REASON=$(echo "$LOG_ENTRY" | jq -r '.reason != null')
  HAS_ACTION=$(echo "$LOG_ENTRY" | jq -r '.action == "skip"')
  
  if [ "$HAS_LINE" == "true" ] && [ "$HAS_REASON" == "true" ] && [ "$HAS_ACTION" == "true" ]; then
    echo "PASS: All required fields present (line, reason, action)"
  else
    echo "FAIL: Missing required fields"
  fi
else
  echo "FAIL: No log entries with required fields found"
fi

# Step 6: Verify no stacktraces in logs
STACKTRACE=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=200 | grep -i "stacktrace\|panic\|goroutine" || echo "")

if [ -z "$STACKTRACE" ]; then
  echo "PASS: No stacktraces in logs"
else
  echo "FAIL: Found stacktrace in logs"
  echo "$STACKTRACE"
fi

# Step 7: Test multiple invalid entries (stress test)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |-
    $(for i in {1..10}; do echo "INVALID-ENTRY-$i"; done)
    CN=COMPANY-K8S-stress-test-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
EOF

sleep 10

# Verify operator still running and valid entry processed
kubectl get pod -n permissions-binder-operator -l control-plane=controller-manager -o jsonpath='{.items[0].status.phase}' | grep "Running" && echo "PASS: Operator survived stress test" || echo "FAIL: Operator crashed during stress test"

kubectl get namespace stress-test && echo "PASS: Valid entry processed despite many invalid entries" || echo "FAIL: Valid entry not processed"

# Step 8: Verify same invalid entry doesn't cause repeated error attempts
INVALID_COUNT=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=500 | jq -r 'select(.message | contains("Skipping invalid")) | select(.cn == "INVALID-ENTRY-1") | .line' | wc -l)

echo "Invalid entry logged $INVALID_COUNT times"

# Each reconciliation should log it once, but not repeatedly in same reconciliation
if [ "$INVALID_COUNT" -le 5 ]; then
  echo "PASS: Invalid entry not logged excessively"
else
  echo "WARN: Invalid entry logged many times ($INVALID_COUNT), may indicate retry loop"
fi
```

**Expected Result**:
- ✅ Operator continues running (doesn't crash on invalid entries)
- ✅ Valid entries processed successfully despite invalid entries
- ✅ Invalid entries logged as INFO level (not ERROR)
- ✅ Log entries contain: line number, CN value, reason, action="skip"
- ✅ No stacktraces in logs
- ✅ Operator handles many invalid entries without performance degradation
- ✅ Same invalid entry logged once per reconciliation (not repeatedly)
- ✅ Valid entries processed even when mixed with invalid entries

**Log Format Verification**:
```bash
# Expected log format (JSON)
{
  "level": "info",
  "msg": "Skipping invalid permission string - cannot parse CN value",
  "line": 3,
  "cn": "COMPANY-K8S-ns-unknownrole",
  "reason": "no matching role found in roleMapping for: COMPANY-K8S-ns-unknownrole (available roles: [engineer admin])",
  "action": "skip"
}
```

**Related Bug**: Fixed in v1.5.3 - Improved error handling for invalid whitelist entries

---

