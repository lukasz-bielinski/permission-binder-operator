#!/bin/bash
# Test 41: ServiceAccount Permission Updates
#
# Self-contained under the first-owner-wins ownership gate (issue #43, PR #45):
# provisions its OWN ConfigMap resolving to a DEDICATED namespace, then walks
# the RoleBinding through view -> admin -> view via PermissionBinder spec
# updates, hard-asserting every transition (the old version silently accepted
# missed upgrades/downgrades via info_log).
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

PB_NAME="test-sa-permission-update"
CM_NAME="sa-test-config-41"
# Dedicated namespace (prefix empty in legacy single-instance mode)
TEST_NS="${TEST_NS_PREFIX}sa-test-41"
SA_NAME="${TEST_NS}-sa-perm-test"
RB_NAME="sa-${TEST_NS}-perm-test"

# apply_pb_with_role <clusterrole> - (re)apply the PB mapping perm-test to it,
# then touch the ConfigMap: a serviceAccountMapping-only change does not bust
# the operator's skip guard (change detection hashes ConfigMap version +
# roleMapping only), so the ConfigMap annotation drives the actual reprocess -
# matching this scenario's title (permission updates VIA CONFIGMAP).
apply_pb_with_role() {
    _apply_pb_spec_with_role "$1"
    kubectl_retry kubectl annotate configmap "$CM_NAME" -n "$NAMESPACE" \
        test-reconcile="$(date +%s%N)" --overwrite >/dev/null 2>&1
}

_apply_pb_spec_with_role() {
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
    perm-test: $1
EOF
}

# rb_has_role <clusterrole> - RoleBinding exists and binds the given role
# (roleRef updates are delete+recreate, so the RB may transiently be absent)
rb_has_role() {
    [ "$(kubectl get rolebinding "$RB_NAME" -n "$TEST_NS" \
        -o jsonpath='{.roleRef.name}' 2>/dev/null)" == "$1" ]
}

# ============================================================================
# ============================================================================
echo "Test 41: ServiceAccount Permission Updates"
echo "--------------------------------------------"

if ! create_sa_test_configmap "$CM_NAME" "$TEST_NS"; then
    fail_test "Could not create test ConfigMap $CM_NAME"
    exit 1
fi

apply_pb_with_role "view"

if ! wait_for_sa "$TEST_NS" "$SA_NAME" 90; then
    fail_test "ServiceAccount $SA_NAME not created within $(e2e_max_wait 90)s"
    exit 1
fi

if wait_for_cmd 60 rb_has_role "view"; then
    pass_test "Initial permissions set correctly (view)"
else
    fail_test "Initial RoleBinding $RB_NAME does not bind 'view' within $(e2e_max_wait 60)s"
    exit 1
fi

SA_UID_BEFORE=$(kubectl get sa "$SA_NAME" -n "$TEST_NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)

# Upgrade permissions
apply_pb_with_role "admin"

if wait_for_cmd 60 rb_has_role "admin"; then
    pass_test "Permission upgrade applied (view -> admin)"
else
    fail_test "Permission upgrade not applied within $(e2e_max_wait 60)s (RoleBinding still $(kubectl get rolebinding "$RB_NAME" -n "$TEST_NS" -o jsonpath='{.roleRef.name}' 2>/dev/null))"
    exit 1
fi

# ServiceAccount must not be recreated during the permission update
SA_UID_AFTER=$(kubectl get sa "$SA_NAME" -n "$TEST_NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
if [ -n "$SA_UID_AFTER" ] && [ "$SA_UID_AFTER" == "$SA_UID_BEFORE" ]; then
    pass_test "ServiceAccount not recreated during permission update"
else
    fail_test "ServiceAccount recreated or missing during permission update"
    exit 1
fi

# Downgrade permissions
apply_pb_with_role "view"

if wait_for_cmd 60 rb_has_role "view"; then
    pass_test "Permission downgrade applied (admin -> view)"
else
    fail_test "Permission downgrade not applied within $(e2e_max_wait 60)s"
    exit 1
fi

echo ""

# ============================================================================
