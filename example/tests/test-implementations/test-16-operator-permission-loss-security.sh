#!/bin/bash
# Test 16: Operator Permission Loss Security
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 16: Operator Permission Loss (Security)"
echo "----------------------------------------------"

# This test removes the operator's permission to manage RoleBindings, forces a
# RoleBinding create, and checks that the operator degrades gracefully (error
# logged with context, namespace created, RoleBinding withheld, CR condition
# published) and recovers once the permission is restored (issue #80).
#
# The shipped ClusterRole is operator-manager-role (example/deployment/
# operator-deployment.yaml); the isolated runner suffixes it with -${INSTANCE}.
# The backup is stripped of resourceVersion/uid/managedFields so the restore is
# an unconditional `kubectl replace` (no 409 conflict). The restore also runs
# from the EXIT trap, so an aborted test never leaves RBAC degraded for the
# tests that follow.
MANAGER_ROLE="operator-manager-role${INSTANCE:+-$INSTANCE}"
OPERATOR_SA="system:serviceaccount:${NAMESPACE}:operator-controller-manager"
BACKUP="${RUN_DIR:-/tmp}/clusterrole-${MANAGER_ROLE}-backup.json"
# Test namespace carries the per-instance prefix (empty in legacy mode)
TEST16_NS="${TEST_NS_PREFIX}test-16-rbac-loss"
WHITELIST_TMP="${RUN_DIR:-/tmp}/whitelist-test16.txt"
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)

op_logs() {
    kubectl logs -n "$NAMESPACE" deployment/operator-controller-manager \
        --since-time="$T0" 2>/dev/null
}
rule_count() {
    kubectl get clusterrole "$MANAGER_ROLE" -o json 2>/dev/null | jq '.rules | length'
}
rolebindings_rule_count() {
    kubectl get clusterrole "$MANAGER_ROLE" -o json 2>/dev/null \
        | jq '[.rules[] | select(.resources[]? == "rolebindings")] | length'
}
restore_role() {
    [ -s "$BACKUP" ] && kubectl replace -f "$BACKUP" >/dev/null 2>&1
}
trap 'restore_role; rm -f "$BACKUP" "$WHITELIST_TMP"' EXIT

# ----------------------------------------------------------------------------
# 0. Preflight: back up the ClusterRole and fail loudly when it is missing
#    (the previous version of this test targeted a name that never existed
#    and passed on nothing)
# ----------------------------------------------------------------------------
kubectl_retry kubectl get clusterrole "$MANAGER_ROLE" -o json 2>/dev/null \
    | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
              .metadata.managedFields, .metadata.generation)' > "$BACKUP" 2>/dev/null
if ! jq -e '.rules | length > 0' "$BACKUP" >/dev/null 2>&1; then
    fail_test "ClusterRole $MANAGER_ROLE not found - cannot exercise permission loss"
    rm -f "$BACKUP"
    echo ""
    exit 1
fi
RULES_BEFORE=$(jq '.rules | length' "$BACKUP")
RB_RULE_INDEX=$(jq '[.rules[] | ((.resources | index("rolebindings")) != null)] | index(true)' "$BACKUP")
if [ -z "$RB_RULE_INDEX" ] || [ "$RB_RULE_INDEX" = "null" ]; then
    fail_test "ClusterRole $MANAGER_ROLE has no rolebindings rule - nothing to remove"
    echo ""
    exit 1
fi
info_log "ClusterRole $MANAGER_ROLE backed up ($RULES_BEFORE rules, rolebindings rule at index $RB_RULE_INDEX), T0=$T0"

# ----------------------------------------------------------------------------
# 1. Remove the rolebindings rule and wait until the authorizer enforces it
# ----------------------------------------------------------------------------
if kubectl patch clusterrole "$MANAGER_ROLE" --type=json \
       -p "[{\"op\":\"remove\",\"path\":\"/rules/${RB_RULE_INDEX}\"}]" >/dev/null 2>&1 \
   && [ "$(rolebindings_rule_count)" = "0" ]; then
    pass_test "Removed rolebindings rule from $MANAGER_ROLE ($RULES_BEFORE -> $(rule_count) rules)"
else
    fail_test "Failed to remove the rolebindings rule from $MANAGER_ROLE"
    echo ""
    exit 1
fi
sa_can_create_rb()    { kubectl auth can-i create rolebindings -n "$NAMESPACE" --as="$OPERATOR_SA" >/dev/null 2>&1; }
sa_cannot_create_rb() { ! sa_can_create_rb; }
if wait_for_cmd 30 sa_cannot_create_rb; then
    info_log "kubectl auth can-i create rolebindings --as=$OPERATOR_SA -> no"
else
    info_log "can-i still reports 'yes' after 30s (authorizer lag) - continuing"
fi

# ----------------------------------------------------------------------------
# 2. Force a RoleBinding create through a whitelist entry. A ConfigMap update
#    is the event the reconciler acts on (annotating the PermissionBinder is
#    filtered out by its predicate as a metadata-only change).
# ----------------------------------------------------------------------------
NEW_ENTRY="CN=COMPANY-K8S-${TEST16_NS}-admin,OU=TestOU,DC=example,DC=com"
kubectl_retry kubectl get configmap permission-config -n "$NAMESPACE" -o jsonpath='{.data.whitelist\.txt}' > "$WHITELIST_TMP"
echo "$NEW_ENTRY" >> "$WHITELIST_TMP"
kubectl create configmap permission-config -n "$NAMESPACE" --from-file=whitelist.txt="$WHITELIST_TMP" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null 2>&1
info_log "Appended whitelist entry for $TEST16_NS (RoleBinding ${TEST16_NS}-admin must now be forbidden)"

# ----------------------------------------------------------------------------
# 3. Forbidden error logged with context, graceful degradation, CR condition
# ----------------------------------------------------------------------------
forbidden_lines() {
    op_logs | grep 'Failed to create RoleBinding' | grep -F "$TEST16_NS" | grep -i 'forbidden'
}
check_forbidden() { forbidden_lines | grep -q .; }
if wait_for_cmd 60 check_forbidden; then
    pass_test "Operator logged the permission error after RBAC loss ($(forbidden_lines | wc -l) forbidden RoleBinding lines since T0)"
    FIRST=$(forbidden_lines | head -1)
    if printf '%s' "$FIRST" | jq -e --arg ns "$TEST16_NS" \
           '.level == "error" and .namespace == $ns and .role == "admin" and (.error | test("forbidden"; "i"))' >/dev/null 2>&1; then
        pass_test "Permission error is structured JSON with error/namespace/role context"
    else
        fail_test "Permission error line is not parseable JSON with error/namespace/role: ${FIRST:0:200}"
    fi
else
    fail_test "No 'Failed to create RoleBinding ... forbidden' log line for $TEST16_NS within 60s of removing the rolebindings rule"
fi

if kubectl get namespace "$TEST16_NS" >/dev/null 2>&1 \
   && ! kubectl get rolebinding "${TEST16_NS}-admin" -n "$TEST16_NS" >/dev/null 2>&1; then
    pass_test "Graceful degradation: namespace $TEST16_NS created, RoleBinding ${TEST16_NS}-admin withheld while forbidden"
else
    fail_test "Expected namespace $TEST16_NS present and RoleBinding ${TEST16_NS}-admin absent while forbidden"
fi

processed_condition() {
    kubectl get permissionbinder permissionbinder-example -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Processed")].status}/{.status.conditions[?(@.type=="Processed")].reason}' 2>/dev/null
}
check_incomplete() { [ "$(processed_condition)" = "False/ProcessingIncomplete" ]; }
if wait_for_cmd 30 check_incomplete; then
    pass_test "Processed=False/ProcessingIncomplete published on the PermissionBinder while forbidden"
else
    fail_test "Processed condition is '$(processed_condition)' while forbidden (want False/ProcessingIncomplete)"
fi

# ----------------------------------------------------------------------------
# 4. Restore the ClusterRole, re-trigger, verify recovery
# ----------------------------------------------------------------------------
if kubectl replace -f "$BACKUP" >/dev/null 2>&1 \
   && [ "$(rule_count)" = "$RULES_BEFORE" ] && [ "$(rolebindings_rule_count)" = "1" ]; then
    pass_test "Restored $MANAGER_ROLE from backup ($RULES_BEFORE rules, rolebindings rule back)"
else
    fail_test "Failed to restore $MANAGER_ROLE from backup (rules $(rule_count)/$RULES_BEFORE, rolebindings rules $(rolebindings_rule_count))"
fi
if ! wait_for_cmd 30 sa_can_create_rb; then
    info_log "can-i still reports 'no' after 30s (authorizer lag) - continuing"
fi
# The failed pass left the reconcile in exponential backoff and deliberately
# did not stamp the ConfigMap version; touching the ConfigMap (new
# resourceVersion) enqueues a fresh full pass immediately.
kubectl annotate configmap permission-config -n "$NAMESPACE" test-rbac-restore="$(date +%s)" --overwrite >/dev/null 2>&1
check_rb() { kubectl get rolebinding "${TEST16_NS}-admin" -n "$TEST16_NS" >/dev/null 2>&1; }
if wait_for_cmd 120 check_rb; then
    pass_test "Operator recovered: RoleBinding ${TEST16_NS}-admin created after RBAC restoration"
else
    fail_test "RoleBinding ${TEST16_NS}-admin not created within 120s after restoring RBAC"
fi
check_processed() { [ "$(processed_condition)" = "True/ConfigMapProcessed" ]; }
if wait_for_cmd 30 check_processed; then
    pass_test "Processed=True/ConfigMapProcessed published after recovery"
else
    fail_test "Processed condition is '$(processed_condition)' after recovery (want True/ConfigMapProcessed)"
fi
DEPLOYMENT_READY=$(kubectl_retry kubectl get deployment operator-controller-manager -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" = "True" ]; then
    pass_test "Operator deployment Available after RBAC restoration"
else
    fail_test "Operator deployment not Available after RBAC restoration (Available=$DEPLOYMENT_READY)"
fi

echo ""

# ============================================================================
