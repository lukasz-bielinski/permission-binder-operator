#!/bin/bash
# Test 09: Operator Restart Recovery
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 9: Operator Restart Recovery"
echo "-----------------------------------"

# Recreate PermissionBinder first (needed for operator to work).
# Inline fixture instead of example/permissionbinder/permissionbinder-example.yaml:
# the example hardcodes namespace permissions-binder-operator (breaks per-instance
# runs) and enables NetworkPolicy GitOps against a real GitHub repo, which has no
# place in a restart-recovery test. Spec mirrors the example minus networkPolicy.
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: permissionbinder-example
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: permission-binder-operator
    app.kubernetes.io/instance: example
spec:
  roleMapping:
    engineer: edit
    admin: admin
    viewer: view
    read-only: read-only
  prefixes:
    - "MT-K8S-DEV-K8S"
    - "COMPANY-K8S"
    - "MT-K8S"
  excludeList:
    - "COMPANY-K8S-HPA-admin"
    - "MT-K8S-SYSTEM-admin"
    - "MT-K8S-MONITORING-viewer"
  configMapName: "permission-config"
  configMapNamespace: "$NAMESPACE"
  createLdapGroups: false
EOF
sleep 5

# Count resources before restart (instance-scoped label from test-common.sh)
RB_BEFORE_RESTART=$(kubectl_retry kubectl get rolebindings -A -l "$MANAGED_BY_LABEL" --no-headers | wc -l)
NS_BEFORE_RESTART=$(kubectl_retry kubectl get namespaces -l "$MANAGED_BY_LABEL" --no-headers | wc -l)

# Restart operator
kubectl rollout restart deployment operator-controller-manager -n $NAMESPACE >/dev/null 2>&1
kubectl rollout status deployment operator-controller-manager -n $NAMESPACE --timeout=60s >/dev/null 2>&1
sleep 15

# Count resources after restart (instance-scoped label from test-common.sh)
RB_AFTER_RESTART=$(kubectl_retry kubectl get rolebindings -A -l "$MANAGED_BY_LABEL" --no-headers | wc -l)
NS_AFTER_RESTART=$(kubectl_retry kubectl get namespaces -l "$MANAGED_BY_LABEL" --no-headers | wc -l)

# Verify no duplicates created
if [ "$RB_AFTER_RESTART" -eq "$RB_BEFORE_RESTART" ] && [ "$NS_AFTER_RESTART" -eq "$NS_BEFORE_RESTART" ]; then
    pass_test "Operator recovered without creating duplicates"
    info_log "Resources stable: $RB_AFTER_RESTART RoleBindings, $NS_AFTER_RESTART Namespaces"
else
    fail_test "Resource count changed (RB: $RB_BEFORE_RESTART→$RB_AFTER_RESTART, NS: $NS_BEFORE_RESTART→$NS_AFTER_RESTART)"
fi

echo ""

# ============================================================================
