#!/bin/bash
# Test 60: NetworkPolicy - Disabled Mode
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 60: NetworkPolicy - Disabled Mode"
echo "---------------------------------------"

BINDER_NAME="test-permissionbinder-networkpolicy-disabled"
CONFIGMAP_NAME="permission-config-disabled"
TEST_NAMESPACE="test-disabled"

cleanup_resources() {
    kubectl delete permissionbinder "$BINDER_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    kubectl delete configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
}

trap cleanup_resources EXIT

# ----------------------------------------------------------------------------
# 1. Create PermissionBinder with networkPolicy disabled
# ----------------------------------------------------------------------------
info_log "Creating PermissionBinder $BINDER_NAME with networkPolicy disabled"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: $BINDER_NAME
  namespace: $NAMESPACE
spec:
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: "edit"
  configMapName: "$CONFIGMAP_NAME"
  configMapNamespace: "$NAMESPACE"
  networkPolicy:
    enabled: false
EOF

# ----------------------------------------------------------------------------
# 2. Create ConfigMap to simulate whitelist (should be ignored)
# ----------------------------------------------------------------------------
info_log "Creating ConfigMap $CONFIGMAP_NAME"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIGMAP_NAME
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-$TEST_NAMESPACE-engineer,OU=Openshift,DC=example,DC=com
EOF

info_log "Waiting for reconciliation (10s)"
sleep 10

# ----------------------------------------------------------------------------
# 3. Validate no NetworkPolicy activity
# ----------------------------------------------------------------------------
STATUS_RAW=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.networkPolicies}' 2>/dev/null || echo "")
if [ -z "$STATUS_RAW" ] || [ "$STATUS_RAW" == "[]" ]; then
    pass_test "No NetworkPolicy status entries created (as expected)"
else
    fail_test "Unexpected NetworkPolicy status entries: $STATUS_RAW"
fi

# Ensure metrics have no entries referencing namespace
METRIC_MATCH=$(curl -s http://localhost:8080/metrics 2>/dev/null | grep "test-disabled" || true)
if [ -z "$METRIC_MATCH" ]; then
    pass_test "No NetworkPolicy metrics emitted for disabled configuration"
else
    fail_test "Unexpected metrics emitted for disabled configuration: $METRIC_MATCH"
fi

# Operator remains healthy
DEPLOYMENT_READY=$(kubectl get deployment operator-controller-manager -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator deployment remains Available"
else
    fail_test "Operator deployment not available"
fi

echo ""

# ============================================================================
