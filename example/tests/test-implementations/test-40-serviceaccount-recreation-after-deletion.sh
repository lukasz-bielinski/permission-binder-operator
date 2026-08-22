#!/bin/bash
# Test 40: ServiceAccount Recreation After Deletion
#
# Self-contained under the first-owner-wins ownership gate (issue #43, PR #45):
# provisions its OWN ConfigMap resolving to a DEDICATED namespace. Reconcile is
# re-triggered by annotating the test's own ConfigMap (the operator does not
# watch ServiceAccounts) instead of deleting the operator pod.
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

PB_NAME="test-sa-recreation"
CM_NAME="sa-test-config-40"
# Dedicated namespace (prefix empty in legacy single-instance mode)
TEST_NS="${TEST_NS_PREFIX}sa-test-40"
SA_NAME="${TEST_NS}-sa-recreation-test"
RB_NAME="sa-${TEST_NS}-recreation-test"

# ============================================================================
# ============================================================================
echo "Test 40: ServiceAccount Recreation After Deletion"
echo "---------------------------------------------------"

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
    recreation-test: edit
EOF

if ! wait_for_sa "$TEST_NS" "$SA_NAME" 90; then
    fail_test "ServiceAccount $SA_NAME not created within $(e2e_max_wait 90)s"
    exit 1
fi

ORIGINAL_SA_UID=$(kubectl get sa "$SA_NAME" -n "$TEST_NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
if [ -z "$ORIGINAL_SA_UID" ]; then
    fail_test "Could not read UID of ServiceAccount $SA_NAME"
    exit 1
fi
info_log "Original SA UID: ${ORIGINAL_SA_UID:0:8}..."

# Delete the ServiceAccount (kubectl delete waits for actual removal)
kubectl_retry kubectl delete sa "$SA_NAME" -n "$TEST_NS" >/dev/null 2>&1

# Trigger reconciliation (operator does not watch ServiceAccounts)
kubectl_retry kubectl annotate configmap "$CM_NAME" -n "$NAMESPACE" \
    test-reconcile="$(date +%s)" --overwrite >/dev/null 2>&1

if wait_for_sa "$TEST_NS" "$SA_NAME" 90; then
    pass_test "ServiceAccount automatically recreated"
else
    fail_test "ServiceAccount not recreated within $(e2e_max_wait 90)s"
    exit 1
fi

# The recreated SA must be a NEW object instance (different UID)
NEW_SA_UID=$(kubectl get sa "$SA_NAME" -n "$TEST_NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
if [ -n "$NEW_SA_UID" ] && [ "$ORIGINAL_SA_UID" != "$NEW_SA_UID" ]; then
    pass_test "New ServiceAccount instance created (different UID)"
else
    fail_test "ServiceAccount UID unchanged - deletion/recreation did not happen"
    exit 1
fi

# RoleBinding must reference the recreated ServiceAccount
RB_SUBJECT=$(kubectl get rolebinding "$RB_NAME" -n "$TEST_NS" \
    -o jsonpath='{.subjects[0].name}' 2>/dev/null)
if [ "$RB_SUBJECT" == "$SA_NAME" ]; then
    pass_test "RoleBinding references recreated ServiceAccount"
else
    fail_test "RoleBinding missing or references wrong subject (got: ${RB_SUBJECT:-<none>}, want: $SA_NAME)"
    exit 1
fi

echo ""

# ============================================================================
