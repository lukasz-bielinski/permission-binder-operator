#!/bin/bash
# Test 34: ServiceAccount Status Tracking
#
# Self-contained under the first-owner-wins ownership gate (issue #43, PR #45):
# provisions its OWN ConfigMap resolving to a DEDICATED namespace. Reusing the
# baseline ConfigMap left this CR with zero owned namespaces, so
# status.processedServiceAccounts stayed empty and the test failed for the
# wrong reason (test harness collision, not an operator bug).
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

PB_NAME="test-sa-status-tracking"
CM_NAME="sa-test-config-34"
# Dedicated namespace (prefix empty in legacy single-instance mode)
TEST_NS="${TEST_NS_PREFIX}sa-test-34"
SA_NAME="${TEST_NS}-sa-status-test"

# ============================================================================
# ============================================================================
echo "Test 34: ServiceAccount Status Tracking"
echo "-----------------------------------------"

if ! create_sa_test_configmap "$CM_NAME" "$TEST_NS"; then
    fail_test "Could not create test ConfigMap $CM_NAME"
    exit 1
fi

apply_yaml_with_retry <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: $PB_NAME
  namespace: $NAMESPACE
spec:
  configMapName: $CM_NAME
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    status-test: edit
EOF

# The SA itself must exist before the status can legitimately report it
if ! wait_for_sa "$TEST_NS" "$SA_NAME" 90; then
    fail_test "ServiceAccount $SA_NAME not created within $(e2e_max_wait 90)s"
    exit 1
fi

# status.processedServiceAccounts entries have the form "<namespace>/<sa-name>"
EXPECTED_ENTRY="${TEST_NS}/${SA_NAME}"
status_has_entry() {
    kubectl get permissionbinder "$PB_NAME" -n "$NAMESPACE" -o json 2>/dev/null \
        | jq -e --arg e "$EXPECTED_ENTRY" \
            '.status.processedServiceAccounts // [] | index($e) != null' >/dev/null
}

if wait_for_cmd 60 status_has_entry; then
    SA_COUNT=$(kubectl get permissionbinder "$PB_NAME" -n "$NAMESPACE" -o json 2>/dev/null \
        | jq '.status.processedServiceAccounts // [] | length')
    info_log "Processed ServiceAccounts tracked: $SA_COUNT"
    pass_test "ServiceAccount status tracking works"
else
    CURRENT=$(kubectl get permissionbinder "$PB_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.processedServiceAccounts}' 2>/dev/null)
    fail_test "status.processedServiceAccounts missing entry $EXPECTED_ENTRY (current: ${CURRENT:-<empty>})"
    exit 1
fi

echo ""

# ============================================================================
