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

        # Scope the query to THIS operator pod (issue #92): the runner deploys
        # a fresh pod per test, and Prometheus keeps series queryable for 5m
        # after the target disappears, so an unscoped query can be satisfied
        # by the previous pod's stale series. The ServiceMonitor does not
        # relabel pod, but instance defaults to <podIP>:8080.
        OPERATOR_POD_IP=$(kubectl get pod -n "$NAMESPACE" -l control-plane=controller-manager \
            -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
        if [ -z "$OPERATOR_POD_IP" ]; then
            fail_test "Operator pod IP not readable - cannot scope the Prometheus query to the current pod"
        else
            # Instance- and pod-scoped query: only series THIS pod exports
            Q_RB="permission_binder_managed_rolebindings_total{namespace=\"${NAMESPACE:?}\",instance=~\"${OPERATOR_POD_IP}:.*\"}"

            # Poll instead of a fixed wait: prometheus-operator config
            # propagation (watch -> Secret -> config-reloader -> reload) takes
            # ~90-120s worst case, plus one 30s scrape interval. Budget
            # ~180s in 15s steps, scaled by E2E_WAIT_MULT.
            MAX_WAIT=$(e2e_max_wait 180)
            STEP=$(e2e_max_wait 15)
            info_log "⏳ Polling Prometheus for operator metrics (up to ${MAX_WAIT}s, pod ${OPERATOR_POD_IP})..."
            ELAPSED=0
            METRICS_COUNT=0
            while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
                METRICS_COUNT=$(prom_query_raw "$Q_RB" | jq -r '.data.result | length')
                if [ "$METRICS_COUNT" -gt 0 ]; then
                    break
                fi
                e2e_sleep 15
                ELAPSED=$((ELAPSED + STEP))
            done

            if [ "$METRICS_COUNT" -gt 0 ]; then
                pass_test "Prometheus collecting operator metrics (after ${ELAPSED}s)"
                CURRENT_RB=$(prom_query "$Q_RB")
                info_log "Current RoleBindings metric: $CURRENT_RB"
            else
                fail_test "Prometheus not collecting metrics from the current operator pod after ${MAX_WAIT}s (check ServiceMonitor and Service labels)"
            fi
        fi
    fi
fi

echo ""

# ============================================================================
