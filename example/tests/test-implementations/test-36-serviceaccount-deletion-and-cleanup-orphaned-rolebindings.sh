#!/bin/bash
# Test 36: ServiceAccount Deletion and Cleanup
#
# Self-contained under the first-owner-wins ownership gate (issue #43, PR #45):
# provisions its OWN ConfigMap resolving to a DEDICATED namespace. Reconcile is
# re-triggered by annotating the test's own ConfigMap (bumps ResourceVersion,
# hits the operator's ConfigMap watch) instead of deleting the operator pod -
# same effect, no pod churn.
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

PB_NAME="test-sa-cleanup"
CM_NAME="sa-test-config-36"
# Dedicated namespace (prefix empty in legacy single-instance mode)
TEST_NS="${TEST_NS_PREFIX}sa-test-36"
SA_NAME="${TEST_NS}-sa-cleanup-test"
RB_NAME="sa-${TEST_NS}-cleanup-test"

# ============================================================================
# ============================================================================
echo "Test 36: ServiceAccount Deletion and Cleanup"
echo "----------------------------------------------"

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
    cleanup-test: edit
EOF

if ! wait_for_sa "$TEST_NS" "$SA_NAME" 90; then
    fail_test "ServiceAccount $SA_NAME not created within $(e2e_max_wait 90)s"
    exit 1
fi
if ! wait_for_cmd 60 kubectl get rolebinding "$RB_NAME" -n "$TEST_NS"; then
    fail_test "RoleBinding $RB_NAME not created within $(e2e_max_wait 60)s"
    exit 1
fi
info_log "RoleBinding: $RB_NAME"

# Manually delete the ServiceAccount
kubectl_retry kubectl delete sa "$SA_NAME" -n "$TEST_NS" >/dev/null 2>&1

# Trigger reconciliation (operator does not watch ServiceAccounts)
kubectl_retry kubectl annotate configmap "$CM_NAME" -n "$NAMESPACE" \
    test-reconcile="$(date +%s)" --overwrite >/dev/null 2>&1

# Operator must recreate the ServiceAccount
if wait_for_sa "$TEST_NS" "$SA_NAME" 90; then
    pass_test "ServiceAccount automatically recreated after deletion"
else
    fail_test "ServiceAccount not recreated within $(e2e_max_wait 90)s"
    exit 1
fi

# RoleBinding must exist and reference the (recreated) ServiceAccount
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
