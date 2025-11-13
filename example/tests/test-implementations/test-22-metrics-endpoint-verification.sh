#!/bin/bash
# Test 22: Metrics Endpoint Verification
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 22: Metrics Endpoint Verification"
echo "----------------------------------------"

# Use port-forward to access metrics endpoint
kubectl port-forward -n $NAMESPACE svc/operator-controller-manager-metrics-service 8080:8080 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!

# Wait longer for port-forward to establish (increased from 3s to 10s)
info_log "Waiting for port-forward to establish..."
sleep 10

# Query metrics endpoint with retry logic
METRICS_RESPONSE=0
for attempt in 1 2 3; do
    METRICS_RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 http://localhost:8080/metrics 2>/dev/null | grep -c "permission_binder" || echo "0")
    METRICS_RESPONSE=$(echo "$METRICS_RESPONSE" | tr -d '\n' | head -1)
    
    if [ "$METRICS_RESPONSE" -gt 0 ]; then
        info_log "Metrics found on attempt $attempt"
        break
    fi
    
    if [ $attempt -lt 3 ]; then
        info_log "Retry $attempt/3: No metrics yet, waiting 5s..."
        sleep 5
    fi
done

# Kill port-forward
kill $PORT_FORWARD_PID 2>/dev/null || true
wait $PORT_FORWARD_PID 2>/dev/null

if [ "$METRICS_RESPONSE" -gt 0 ]; then
    pass_test "Prometheus metrics endpoint accessible"
    info_log "Found $METRICS_RESPONSE permission_binder metrics"
else
    fail_test "Metrics endpoint not accessible or no custom metrics (tried 3 times)"
fi

echo ""

# ============================================================================
