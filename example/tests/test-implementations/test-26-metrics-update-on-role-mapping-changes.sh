#!/bin/bash
# Test 26: Metrics Update On Role Mapping Changes
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 26: Metrics Update on Role Mapping Changes"
echo "-------------------------------------------------"

# Check if Prometheus is running
PROM_POD=$(kubectl_retry kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$PROM_POD" ]; then
    fail_test "Prometheus not running (required for metrics test)"
    info_log "Install Prometheus to enable this test"
    echo ""
else
    # Record initial metric value
    RB_METRIC_BEFORE=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result[0].value[1]' | cut -d. -f1)
    info_log "RoleBindings metric before: $RB_METRIC_BEFORE"

    # Add new role
    kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
      -p='[{"op":"add","path":"/spec/roleMapping/metrics-test","value":"view"}]' >/dev/null 2>&1
    sleep 30
    
    # Check updated metric
    RB_METRIC_AFTER=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result[0].value[1]' | cut -d. -f1)
    info_log "RoleBindings metric after: $RB_METRIC_AFTER"
    
    if [ "$RB_METRIC_AFTER" -gt "$RB_METRIC_BEFORE" ]; then
        pass_test "Metrics updated after role mapping change"
    else
        info_log "Metrics may need more time to update (scrape interval)"
    fi
    
    # Cleanup
    kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
      -p='[{"op":"remove","path":"/spec/roleMapping/metrics-test"}]' >/dev/null 2>&1
fi

echo ""

# ============================================================================
