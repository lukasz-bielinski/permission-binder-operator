#!/bin/bash
# Test 25: Prometheus Metrics Collection
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 25: Prometheus Metrics Collection"
echo "----------------------------------------"

# Check if Prometheus is running
PROMETHEUS_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | wc -l)
if [ "$PROMETHEUS_POD" -eq 0 ]; then
    info_log "⚠️  Prometheus not installed - skipping metrics tests 25-30"
    info_log "Install Prometheus + ServiceMonitor to enable metrics tests"
    pass_test "Test skipped (Prometheus not available)"
else
    pass_test "Prometheus is running"
    
    # Check if ServiceMonitor exists (required for Prometheus to scrape operator metrics)
    # Check both permissions-binder-operator and monitoring namespaces
    SM_EXISTS=$(kubectl get servicemonitor -A 2>/dev/null | grep "permission-binder-operator" | wc -l)
    SM_EXISTS=$(echo "$SM_EXISTS" | tr -d ' \n')
    if [ "$SM_EXISTS" -eq 0 ]; then
        info_log "⚠️  ServiceMonitor not configured - Prometheus cannot scrape operator metrics"
        info_log "Apply: kubectl apply -f example/deployment/servicemonitor.yaml"
        pass_test "Test skipped (ServiceMonitor not configured)"
    else
        pass_test "ServiceMonitor configured in monitoring namespace"
        PROM_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
        
        # Wait for Prometheus to scrape metrics (scrape_interval: 30s)
        info_log "⏳ Waiting 45s for Prometheus to scrape operator metrics..."
        sleep 45
        
        # Query basic operator metrics
        METRICS_COUNT=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result | length')
        if [ "$METRICS_COUNT" -gt 0 ]; then
            pass_test "Prometheus collecting operator metrics"
            CURRENT_RB=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result[0].value[1]')
            info_log "Current RoleBindings metric: $CURRENT_RB"
        else
            # One more retry after additional wait
            info_log "⏳ Metrics not found, waiting additional 30s..."
            sleep 30
            METRICS_COUNT=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result | length')
            if [ "$METRICS_COUNT" -gt 0 ]; then
                pass_test "Prometheus collecting operator metrics (after extended wait)"
                CURRENT_RB=$(kubectl exec -n monitoring $PROM_POD -- wget -q -O- "http://localhost:9090/api/v1/query?query=permission_binder_managed_rolebindings_total" 2>/dev/null | jq -r '.data.result[0].value[1]')
                info_log "Current RoleBindings metric: $CURRENT_RB"
            else
                fail_test "Prometheus not collecting operator metrics after 75s wait (check ServiceMonitor and Service labels)"
            fi
        fi
    fi
fi

echo ""

# ============================================================================
