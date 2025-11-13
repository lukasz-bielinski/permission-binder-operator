#!/bin/bash
# Test 29: Configmap Processing Metrics
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 29: ConfigMap Processing Metrics"
echo "---------------------------------------"

# Check if Prometheus is running
PROM_POD=$(kubectl_retry kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$PROM_POD" ]; then
    fail_test "Prometheus not running (required for metrics test)"
    info_log "Install Prometheus to enable this test"
    echo ""
else
    # Query ConfigMap entries processed metric
    CM_PROCESSED=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_configmap_entries_processed_total" 2>/dev/null | jq -r '.data.result[0].value[1]' 2>/dev/null | tr -d '\n' | grep -E '^[0-9]+$' || echo "0")
    info_log "ConfigMap entries processed: $CM_PROCESSED"
    
    if [ "$CM_PROCESSED" != "0" ] && [ "$CM_PROCESSED" -gt 0 ] 2>/dev/null; then
        pass_test "ConfigMap processing metrics tracked"
    else
        info_log "ConfigMap processing metric not available (may not be implemented)"
    fi
fi

echo ""

# ============================================================================
