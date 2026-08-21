#!/bin/bash
# Test 37: Cross-Namespace ServiceAccount References
#
# Self-contained under the first-owner-wins ownership gate (issue #43, PR #45):
# the previous version reused the baseline ConfigMap, was refused ownership of
# the baseline-owned namespace, found zero managed namespaces and passed
# VACUOUSLY (every assertion behind an info_log escape). It now provisions its
# OWN ConfigMap resolving to TWO dedicated namespaces and hard-asserts that a
# ServiceAccount exists in each, with each RoleBinding referencing the SA from
# its OWN namespace (cross-namespace isolation).
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

PB_NAME="test-sa-cross-ns"
CM_NAME="sa-test-config-37"
# Two dedicated namespaces (prefix empty in legacy single-instance mode)
TEST_NS_A="${TEST_NS_PREFIX}sa-test-37"
TEST_NS_B="${TEST_NS_PREFIX}sa-test-37-b"

# ============================================================================
# ============================================================================
echo "Test 37: Cross-Namespace ServiceAccount References"
echo "----------------------------------------------------"

if ! create_sa_test_configmap "$CM_NAME" "$TEST_NS_A" "$TEST_NS_B"; then
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
    cross-ns-test: view
EOF

if ! wait_for_sa "$TEST_NS_A" "${TEST_NS_A}-sa-cross-ns-test" 90 \
    || ! wait_for_sa "$TEST_NS_B" "${TEST_NS_B}-sa-cross-ns-test" 60; then
    fail_test "ServiceAccounts not created in both namespaces ($TEST_NS_A, $TEST_NS_B)"
    exit 1
fi
pass_test "ServiceAccounts created in multiple namespaces (2 namespaces)"

# Each RoleBinding must reference the ServiceAccount from its OWN namespace
ISOLATION_OK=0
for ns in "$TEST_NS_A" "$TEST_NS_B"; do
    RB_SA_NAME=$(kubectl get rolebinding "sa-${ns}-cross-ns-test" -n "$ns" \
        -o jsonpath='{.subjects[0].name}' 2>/dev/null)
    RB_SA_NS=$(kubectl get rolebinding "sa-${ns}-cross-ns-test" -n "$ns" \
        -o jsonpath='{.subjects[0].namespace}' 2>/dev/null)
    if [ "$RB_SA_NAME" == "${ns}-sa-cross-ns-test" ] && [ "$RB_SA_NS" == "$ns" ]; then
        ISOLATION_OK=$((ISOLATION_OK + 1))
    else
        info_log "Namespace $ns: RoleBinding subject ${RB_SA_NAME:-<none>}/${RB_SA_NS:-<none>} does not reference local SA"
    fi
done

if [ $ISOLATION_OK -eq 2 ]; then
    pass_test "Cross-namespace isolation verified (RoleBindings reference local SAs)"
else
    fail_test "Cross-namespace isolation broken ($ISOLATION_OK/2 namespaces OK)"
    exit 1
fi

echo ""

# ============================================================================
