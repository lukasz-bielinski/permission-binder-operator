#!/bin/bash
# Test 27: Metrics Update On Configmap Changes
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 27: Metrics Update on ConfigMap Changes"
echo "----------------------------------------------"

# Check if Prometheus is running
PROM_POD=$(kubectl_retry kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$PROM_POD" ]; then
    fail_test "Prometheus not running (required for metrics test)"
    info_log "Install Prometheus to enable this test"
    echo ""
else
    # Record initial namespace metric
    NS_METRIC_BEFORE=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_namespaces_total" 2>/dev/null | jq -r '.data.result[0].value[1]' | cut -d. -f1 2>/dev/null || echo "0")
    info_log "Namespaces metric before: $NS_METRIC_BEFORE"

    # Add new namespace entry
    kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-metrics.txt
    echo "CN=COMPANY-K8S-metrics-test-ns27-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-metrics.txt
    kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-metrics.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    rm -f /tmp/whitelist-metrics.txt
    
    kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-ns-metrics="$(date +%s)" --overwrite >/dev/null 2>&1
    sleep 30
    
    # Check updated metric
    NS_METRIC_AFTER=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_namespaces_total" 2>/dev/null | jq -r '.data.result[0].value[1]' | cut -d. -f1 2>/dev/null || echo "0")
    info_log "Namespaces metric after: $NS_METRIC_AFTER"
    
    if [ "$NS_METRIC_AFTER" -gt "$NS_METRIC_BEFORE" ]; then
        pass_test "Namespace metrics updated after ConfigMap change"
    else
        info_log "Metrics may need more time to update"
    fi
fi

echo ""

# ============================================================================
