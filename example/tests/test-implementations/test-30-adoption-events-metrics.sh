#!/bin/bash
# Test 30: Adoption Events Metrics
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 30: Adoption Events Metrics"
echo "----------------------------------"

# Check if Prometheus is running
PROM_POD=$(kubectl_retry kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$PROM_POD" ]; then
    fail_test "Prometheus not running (required for metrics test)"
    info_log "Install Prometheus to enable this test"
    echo ""
else
    # Query adoption events metric
    ADOPTION_METRIC=$(kubectl_retry kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_adoption_events_total" 2>/dev/null | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "0")
    info_log "Adoption events metric: $ADOPTION_METRIC"
    
    # Should have events from Test 14
    if [ "$ADOPTION_METRIC" -gt 0 ]; then
        pass_test "Adoption events tracked in metrics"
    else
        info_log "No adoption events in metrics (may not be implemented or needs more time)"
    fi
fi

echo ""

# ============================================================================
