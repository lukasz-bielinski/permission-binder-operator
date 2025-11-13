#!/bin/bash
# Test 34: Serviceaccount Status Tracking
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 34: ServiceAccount Status Tracking"
echo "-----------------------------------------"

# Create PermissionBinder for status tracking test
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-status-tracking
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    status-test: edit
EOF

# Give operator time to process and update status
sleep 15

SA_STATUS=$(kubectl get permissionbinder test-sa-status-tracking -n $NAMESPACE -o jsonpath='{.status.processedServiceAccounts}' 2>/dev/null)

if [ ! -z "$SA_STATUS" ] && [ "$SA_STATUS" != "null" ]; then
    SA_COUNT=$(echo "$SA_STATUS" | jq '. | length' 2>/dev/null || echo "0")
    info_log "Processed ServiceAccounts tracked: $SA_COUNT"
    
    if [ "$SA_COUNT" -gt 0 ]; then
        pass_test "ServiceAccount status tracking works"
    else
        fail_test "ServiceAccount status empty"
    fi
else
    # Try to force reconciliation by updating ConfigMap (triggers reconciliation via watch)
    kubectl patch configmap permission-config -n $NAMESPACE --type merge -p '{"data":{"whitelist.txt":"'"$(kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}')"'\n"}}' >/dev/null 2>&1
    sleep 2
    # Revert the change
    kubectl patch configmap permission-config -n $NAMESPACE --type merge -p '{"data":{"whitelist.txt":"'"$(kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' | sed 's/\n$//')"'"}}' >/dev/null 2>&1
    sleep 5
    SA_STATUS=$(kubectl get permissionbinder test-sa-status-tracking -n $NAMESPACE -o jsonpath='{.status.processedServiceAccounts}' 2>/dev/null)
    if [ ! -z "$SA_STATUS" ] && [ "$SA_STATUS" != "null" ]; then
        SA_COUNT=$(echo "$SA_STATUS" | jq '. | length' 2>/dev/null || echo "0")
        if [ "$SA_COUNT" -gt 0 ]; then
            pass_test "ServiceAccount status tracking works"
        else
            fail_test "ServiceAccount status empty"
        fi
    else
        fail_test "ServiceAccount status field not populated"
    fi
fi

echo ""

# ============================================================================
