#!/bin/bash
# Test 38: Multiple ServiceAccounts per Namespace (Scaling)
#
# Self-contained under the first-owner-wins ownership gate (issue #43, PR #45):
# provisions its OWN ConfigMap resolving to a DEDICATED namespace and
# hard-asserts the exact expected ServiceAccount count (8) instead of the old
# info_log escape.
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

PB_NAME="test-sa-multiple"
CM_NAME="sa-test-config-38"
# Dedicated namespace (prefix empty in legacy single-instance mode)
TEST_NS="${TEST_NS_PREFIX}sa-test-38"
SA_KEYS="deploy runtime monitoring cicd backup logging metrics ingress"
EXPECTED_SA_COUNT=8

# ============================================================================
# ============================================================================
echo "Test 38: Multiple ServiceAccounts per Namespace"
echo "-------------------------------------------------"

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
    deploy: admin
    runtime: view
    monitoring: view
    cicd: edit
    backup: edit
    logging: view
    metrics: view
    ingress: edit
EOF

all_sas_present() {
    local key
    for key in $SA_KEYS; do
        kubectl get sa "${TEST_NS}-sa-${key}" -n "$TEST_NS" >/dev/null 2>&1 || return 1
    done
    return 0
}

START_TIME=$(date +%s)
if ! wait_for_cmd 120 all_sas_present; then
    PRESENT=0
    for key in $SA_KEYS; do
        kubectl get sa "${TEST_NS}-sa-${key}" -n "$TEST_NS" >/dev/null 2>&1 && PRESENT=$((PRESENT + 1))
    done
    fail_test "Only $PRESENT/$EXPECTED_SA_COUNT ServiceAccounts created within $(e2e_max_wait 120)s"
    exit 1
fi
DURATION=$(( $(date +%s) - START_TIME ))
info_log "Reconciliation time: ${DURATION}s"
pass_test "Multiple ServiceAccounts created successfully ($EXPECTED_SA_COUNT)"

# Performance envelope (informational threshold preserved from original test)
if [ "$DURATION" -lt "$(e2e_max_wait 30)" ]; then
    pass_test "Reconciliation completed in acceptable time (${DURATION}s < $(e2e_max_wait 30)s)"
else
    info_log "Reconciliation took ${DURATION}s"
fi

# Exactly the expected count - no extra operator-created SAs in the namespace
ACTUAL_SA_COUNT=$(kubectl get sa -n "$TEST_NS" -l "app.kubernetes.io/name=${PB_NAME}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$ACTUAL_SA_COUNT" -eq "$EXPECTED_SA_COUNT" ]; then
    pass_test "Exactly $EXPECTED_SA_COUNT operator-managed ServiceAccounts (no duplicates/extras)"
else
    fail_test "Unexpected operator-managed ServiceAccount count: $ACTUAL_SA_COUNT (expected $EXPECTED_SA_COUNT)"
    exit 1
fi

echo ""

# ============================================================================
