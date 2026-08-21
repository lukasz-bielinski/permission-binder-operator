#!/bin/bash
# Test 33: ServiceAccount Idempotency
#
# Self-contained under the first-owner-wins ownership gate (issue #43, PR #45):
# the original test relied on a ServiceAccount left behind by previous tests
# (state a fully isolated run wipes) and skipped with info_log when it was
# missing. It now provisions its OWN ConfigMap/PermissionBinder/namespace and
# hard-fails when the idempotency re-check cannot run.
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

PB_NAME="test-sa-idempotency"
CM_NAME="sa-test-config-33"
# Dedicated namespace (prefix empty in legacy single-instance mode)
TEST_NS="${TEST_NS_PREFIX}sa-test-33"
SA_NAME="${TEST_NS}-sa-deploy"

# ============================================================================
# ============================================================================
echo "Test 33: ServiceAccount Idempotency"
echo "-------------------------------------"

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
    deploy: edit
EOF

if ! wait_for_sa "$TEST_NS" "$SA_NAME" 90; then
    fail_test "ServiceAccount $SA_NAME not created within $(e2e_max_wait 90)s - cannot run idempotency check"
    exit 1
fi

SA_UID=$(kubectl get sa "$SA_NAME" -n "$TEST_NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
if [ -z "$SA_UID" ]; then
    fail_test "Could not read UID of ServiceAccount $SA_NAME"
    exit 1
fi

# Trigger reconciliation (ConfigMap annotation bumps ResourceVersion -> watch)
kubectl_retry kubectl annotate configmap "$CM_NAME" -n "$NAMESPACE" \
    test-reconcile="$(date +%s)" --overwrite >/dev/null 2>&1

# Observe UID stability across the post-trigger window: a recreated SA would
# surface a new UID within seconds of the reconcile.
for i in 1 2 3; do
    e2e_sleep 5
    NEW_SA_UID=$(kubectl get sa "$SA_NAME" -n "$TEST_NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
    if [ -z "$NEW_SA_UID" ]; then
        fail_test "ServiceAccount $SA_NAME disappeared during reconciliation (check $i/3)"
        exit 1
    fi
    if [ "$NEW_SA_UID" != "$SA_UID" ]; then
        fail_test "ServiceAccount was recreated (UID changed on check $i/3)"
        exit 1
    fi
done
pass_test "ServiceAccount not recreated (idempotent)"

echo ""

# ============================================================================
