#!/bin/bash
# Test 00: Pre-Test - Initial State Verification
# Source common functions (SCRIPT_DIR should be set by parent script)
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Pre-Test: Initial State Verification"
echo "-------------------------------------"

# Check if deployment is available
DEPLOYMENT_READY=$(kubectl_retry kubectl get deployment operator-controller-manager -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator pod is running"
else
    fail_test "Operator deployment not ready"
fi

# Check JSON logging
JSON_VALID_COUNT=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=10 | grep -v "^I" | while read line; do echo "$line" | jq -e '.level' >/dev/null 2>&1 && echo "1"; done | wc -l)
if [ "$JSON_VALID_COUNT" -gt 0 ]; then
    pass_test "JSON structured logging is working"
else
    fail_test "JSON logging not working properly"
fi

# Create or update ConfigMap for testing
if ! kubectl_retry kubectl get configmap permission-config -n $NAMESPACE >/dev/null 2>&1; then
    info_log "Creating test ConfigMap"
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-namespace-001-developer,OU=Groups,DC=example,DC=com
EOF
fi

# Check or create example PermissionBinder for testing
if ! kubectl_retry kubectl get permissionbinder permissionbinder-example -n $NAMESPACE >/dev/null 2>&1; then
    info_log "Creating example PermissionBinder for testing"
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: permissionbinder-example
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    admin: admin
    developer: edit
    viewer: view
EOF
    sleep 3
fi

# Check finalizer
FINALIZER=$(kubectl_retry kubectl get permissionbinder permissionbinder-example -n $NAMESPACE -o jsonpath='{.metadata.finalizers[0]}' 2>/dev/null || echo "not-found")
if [ "$FINALIZER" == "permission-binder.io/finalizer" ]; then
    pass_test "Finalizer is present on PermissionBinder"
else
    info_log "Finalizer: $FINALIZER (may be added during first reconciliation)"
fi

echo ""

# ============================================================================
