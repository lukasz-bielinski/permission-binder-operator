#!/bin/bash
# Test 31: ServiceAccount Creation
#
# Self-contained under the first-owner-wins ownership gate (issue #43, PR #45):
# provisions its OWN ConfigMap resolving to a DEDICATED namespace instead of
# reusing the runner's baseline ConfigMap (permission-config), whose namespace
# is already owned by the baseline PermissionBinder - a second CR referencing
# it is refused ownership and its ServiceAccount loop runs over zero namespaces.
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

PB_NAME="test-sa-basic"
CM_NAME="sa-test-config-31"
# Dedicated namespace (prefix empty in legacy single-instance mode)
TEST_NS="${TEST_NS_PREFIX}sa-test-31"

# ============================================================================
# ============================================================================
echo "Test 31: ServiceAccount Creation"
echo "----------------------------------"

# Own ConfigMap -> this CR is the first (and only) owner of $TEST_NS
if ! create_sa_test_configmap "$CM_NAME" "$TEST_NS"; then
    fail_test "Could not create test ConfigMap $CM_NAME"
    exit 1
fi

# Create PermissionBinder with SA mapping
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
    deploy: edit
    runtime: view
EOF

# Default naming pattern is {namespace}-sa-{name}
if ! wait_for_sa "$TEST_NS" "${TEST_NS}-sa-deploy" 90; then
    fail_test "ServiceAccount ${TEST_NS}-sa-deploy not created within $(e2e_max_wait 90)s"
    exit 1
fi
if ! wait_for_sa "$TEST_NS" "${TEST_NS}-sa-runtime" 60; then
    fail_test "ServiceAccount ${TEST_NS}-sa-runtime not created within $(e2e_max_wait 60)s"
    exit 1
fi
pass_test "ServiceAccounts created (deploy and runtime)"

# SA RoleBindings are named sa-<namespace>-<mapping-key>
if wait_for_cmd 60 kubectl get rolebinding "sa-${TEST_NS}-deploy" -n "$TEST_NS" \
    && wait_for_cmd 30 kubectl get rolebinding "sa-${TEST_NS}-runtime" -n "$TEST_NS"; then
    pass_test "ServiceAccount RoleBindings created"
else
    fail_test "ServiceAccount RoleBindings not created"
    exit 1
fi

echo ""

# ============================================================================
