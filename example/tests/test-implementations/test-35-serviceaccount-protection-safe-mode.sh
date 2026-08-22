#!/bin/bash
# Test 35: ServiceAccount Protection (SAFE MODE)
#
# Self-contained under the first-owner-wins ownership gate (issue #43, PR #45):
# provisions its OWN ConfigMap resolving to a DEDICATED namespace, then removes
# the serviceAccountMapping and hard-asserts the SAFE-MODE guarantee: existing
# ServiceAccounts (and their RoleBindings) are NEVER deleted by the operator.
# Note: the operator does not orphan-annotate ServiceAccounts (SA resources do
# not carry the permission-binder.io/managed-by label the SAFE-MODE cleanup
# selects on), so the old annotation probe asserted unimplemented behavior and
# was dropped.
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

PB_NAME="test-sa-protection"
CM_NAME="sa-test-config-35"
# Dedicated namespace (prefix empty in legacy single-instance mode)
TEST_NS="${TEST_NS_PREFIX}sa-test-35"

# ============================================================================
# ============================================================================
echo "Test 35: ServiceAccount Protection (SAFE MODE)"
echo "-----------------------------------------------"

if ! create_sa_test_configmap "$CM_NAME" "$TEST_NS"; then
    fail_test "Could not create test ConfigMap $CM_NAME"
    exit 1
fi

# Create PermissionBinder with ServiceAccount mapping
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

if ! wait_for_sa "$TEST_NS" "${TEST_NS}-sa-deploy" 90 \
    || ! wait_for_sa "$TEST_NS" "${TEST_NS}-sa-runtime" 60; then
    fail_test "ServiceAccounts not created - cannot run SAFE MODE protection check"
    exit 1
fi

SA_DEPLOY_UID=$(kubectl get sa "${TEST_NS}-sa-deploy" -n "$TEST_NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
SA_RUNTIME_UID=$(kubectl get sa "${TEST_NS}-sa-runtime" -n "$TEST_NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
info_log "ServiceAccounts created (deploy: ${SA_DEPLOY_UID:0:8}..., runtime: ${SA_RUNTIME_UID:0:8}...)"

# Remove the ServiceAccount mapping
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
  serviceAccountMapping: {}
EOF

# A serviceAccountMapping-only change does not bust the operator's skip guard
# (change detection hashes ConfigMap version + roleMapping only), so force a
# full reprocess by annotating the test's own ConfigMap.
kubectl_retry kubectl annotate configmap "$CM_NAME" -n "$NAMESPACE" \
    test-reconcile="$(date +%s)" --overwrite >/dev/null 2>&1

# Wait until the mapping removal reconciled: the Processed condition observes
# the new generation AND processedServiceAccounts drains
mapping_removal_reconciled() {
    kubectl get permissionbinder "$PB_NAME" -n "$NAMESPACE" -o json 2>/dev/null | jq -e '
        (.metadata.generation as $g
         | .status.conditions // [] | any(.type == "Processed" and .observedGeneration == $g))
        and ((.status.processedServiceAccounts // []) | length == 0)' >/dev/null
}
if ! wait_for_cmd 60 mapping_removal_reconciled; then
    fail_test "Mapping removal not reconciled: status.processedServiceAccounts did not drain within $(e2e_max_wait 60)s"
    exit 1
fi

# SAFE MODE: SAs must still exist, untouched (same UIDs)
NEW_SA_DEPLOY_UID=$(kubectl get sa "${TEST_NS}-sa-deploy" -n "$TEST_NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
NEW_SA_RUNTIME_UID=$(kubectl get sa "${TEST_NS}-sa-runtime" -n "$TEST_NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)

if [ "$SA_DEPLOY_UID" == "$NEW_SA_DEPLOY_UID" ] && [ "$SA_RUNTIME_UID" == "$NEW_SA_RUNTIME_UID" ] \
    && [ -n "$NEW_SA_DEPLOY_UID" ] && [ -n "$NEW_SA_RUNTIME_UID" ]; then
    pass_test "ServiceAccounts NEVER deleted (SAFE MODE)"
else
    fail_test "ServiceAccounts were deleted or recreated after mapping removal"
    exit 1
fi

# SA RoleBindings are also preserved (never selected by SAFE-MODE cleanup)
if kubectl get rolebinding "sa-${TEST_NS}-deploy" -n "$TEST_NS" >/dev/null 2>&1 \
    && kubectl get rolebinding "sa-${TEST_NS}-runtime" -n "$TEST_NS" >/dev/null 2>&1; then
    pass_test "ServiceAccount RoleBindings preserved after mapping removal"
else
    fail_test "ServiceAccount RoleBindings were deleted after mapping removal"
    exit 1
fi

echo ""

# ============================================================================
