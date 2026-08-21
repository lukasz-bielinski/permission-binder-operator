#!/bin/bash
# Test 32: ServiceAccount Naming Pattern
#
# Self-contained under the first-owner-wins ownership gate (issue #43, PR #45):
# provisions its OWN ConfigMap resolving to a DEDICATED namespace instead of
# competing with the runner's baseline PermissionBinder for its namespace.
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

PB_NAME="test-sa-pattern"
CM_NAME="sa-test-config-32"
# Dedicated namespace (prefix empty in legacy single-instance mode)
TEST_NS="${TEST_NS_PREFIX}sa-test-32"

# ============================================================================
# ============================================================================
echo "Test 32: ServiceAccount Naming Pattern"
echo "----------------------------------------"

if ! create_sa_test_configmap "$CM_NAME" "$TEST_NS"; then
    fail_test "Could not create test ConfigMap $CM_NAME"
    exit 1
fi

# Create PermissionBinder with custom naming pattern
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
  serviceAccountNamingPattern: "sa-{namespace}-{name}"
EOF

# Custom pattern sa-{namespace}-{name} -> sa-<ns>-deploy
if wait_for_sa "$TEST_NS" "sa-${TEST_NS}-deploy" 90; then
    pass_test "Custom naming pattern works (sa-{namespace}-{name})"
else
    fail_test "Custom naming pattern not applied: ServiceAccount sa-${TEST_NS}-deploy not created within $(e2e_max_wait 90)s"
    exit 1
fi

# The default-pattern name must NOT appear alongside the custom one
if kubectl get serviceaccount "${TEST_NS}-sa-deploy" -n "$TEST_NS" >/dev/null 2>&1; then
    fail_test "Default-pattern ServiceAccount ${TEST_NS}-sa-deploy created despite custom pattern"
    exit 1
fi
pass_test "Default-pattern ServiceAccount not created (custom pattern exclusive)"

echo ""

# ============================================================================
