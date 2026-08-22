#!/bin/bash
# Test 39: ServiceAccount Special Characters & Edge Cases
#
# Self-contained under the first-owner-wins ownership gate (issue #43, PR #45):
# each half of the test provisions its OWN ConfigMap resolving to a DEDICATED
# namespace (valid-characters check and empty-mapping check are fully
# independent CRs, so neither competes for ownership with the other or with
# the runner's baseline PermissionBinder).
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

PB_NAME="test-sa-special-chars"
CM_NAME="sa-test-config-39"
# Dedicated namespaces (prefix empty in legacy single-instance mode)
TEST_NS="${TEST_NS_PREFIX}sa-test-39"
EMPTY_PB_NAME="test-sa-empty"
EMPTY_CM_NAME="sa-test-config-39-empty"
EMPTY_NS="${TEST_NS_PREFIX}sa-test-39-empty"

# ============================================================================
# ============================================================================
echo "Test 39: ServiceAccount Special Characters & Edge Cases"
echo "---------------------------------------------------------"

if ! create_sa_test_configmap "$CM_NAME" "$TEST_NS"; then
    fail_test "Could not create test ConfigMap $CM_NAME"
    exit 1
fi

# Valid characters (hyphens, numbers) in mapping keys
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
    my-deploy-sa: edit
    test-runtime-123: view
EOF

if wait_for_sa "$TEST_NS" "${TEST_NS}-sa-my-deploy-sa" 90 \
    && wait_for_sa "$TEST_NS" "${TEST_NS}-sa-test-runtime-123" 60; then
    pass_test "Valid special characters supported (hyphens, numbers)"
else
    fail_test "ServiceAccounts with hyphens/numbers in mapping keys not created"
    exit 1
fi

# Empty mapping must reconcile cleanly (namespace + RoleBinding, zero SAs)
if ! create_sa_test_configmap "$EMPTY_CM_NAME" "$EMPTY_NS"; then
    fail_test "Could not create test ConfigMap $EMPTY_CM_NAME"
    exit 1
fi

apply_yaml_with_retry <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: $EMPTY_PB_NAME
  namespace: $NAMESPACE
spec:
  configMapName: $EMPTY_CM_NAME
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping: {}
EOF

# The CR must still reconcile its namespace (proves no crash/short-circuit)
if ! wait_for_cmd 90 kubectl get namespace "$EMPTY_NS"; then
    fail_test "Namespace $EMPTY_NS not created - empty serviceAccountMapping broke reconciliation"
    exit 1
fi

# No operator-created ServiceAccounts may appear for the empty mapping
EMPTY_SA_COUNT=$(kubectl get sa -n "$EMPTY_NS" -l "app.kubernetes.io/name=${EMPTY_PB_NAME}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$EMPTY_SA_COUNT" -ne 0 ]; then
    fail_test "Empty serviceAccountMapping created $EMPTY_SA_COUNT ServiceAccount(s)"
    exit 1
fi

# Operator must still be running
POD_STATUS=$(kubectl get pod -n "$NAMESPACE" -l control-plane=controller-manager \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
if [ "$POD_STATUS" == "Running" ]; then
    pass_test "Empty ServiceAccount mapping handled gracefully (no crash)"
else
    fail_test "Operator not running after empty mapping (status: ${POD_STATUS:-<none>})"
    exit 1
fi

echo ""

# ============================================================================
