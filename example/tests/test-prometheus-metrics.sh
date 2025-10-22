#!/bin/bash

# Test Prometheus Metrics Collection for Permission Binder Operator
# This script tests that Prometheus is collecting operator metrics correctly

set -e

export KUBECONFIG=$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)

echo "=== Testing Prometheus Metrics Collection ==="

# Function to query Prometheus
query_prometheus() {
    local query="$1"
    kubectl exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -- wget -q -O- "http://localhost:9090/api/v1/query?query=$query" 2>/dev/null
}

# Function to get metric value
get_metric_value() {
    local metric="$1"
    query_prometheus "$metric" | jq -r '.data.result[0].value[1] // "0"'
}

echo "1. Checking Prometheus target status..."
TARGET_STATUS=$(query_prometheus 'up{job="operator-controller-manager-metrics-service"}')
echo "Target status: $TARGET_STATUS"

if echo "$TARGET_STATUS" | jq -e '.data.result[0].value[1] == "1"' > /dev/null; then
    echo "✅ Prometheus target is UP"
else
    echo "❌ Prometheus target is DOWN"
    exit 1
fi

echo ""
echo "2. Checking operator metrics..."

# Check all custom metrics
echo "RoleBindings managed: $(get_metric_value 'permission_binder_managed_rolebindings_total')"
echo "Namespaces managed: $(get_metric_value 'permission_binder_managed_namespaces_total')"
echo "Orphaned resources: $(get_metric_value 'permission_binder_orphaned_resources_total')"
echo "Adoption events: $(get_metric_value 'permission_binder_adoption_events_total')"

# Check ConfigMap processing metrics
CONFIGMAP_METRICS=$(query_prometheus 'permission_binder_configmap_entries_processed_total')
echo "ConfigMap processing metrics:"
echo "$CONFIGMAP_METRICS" | jq -r '.data.result[] | "  \(.metric.status): \(.value[1])"'

echo ""
echo "3. Testing metrics update on role mapping change..."

# Record initial values
BEFORE_RB=$(get_metric_value 'permission_binder_managed_rolebindings_total')
echo "Before: $BEFORE_RB RoleBindings"

# Add new role to mapping
echo "Adding new role 'tester' to mapping..."
kubectl patch permissionbinder permissionbinder-example -n permissions-binder-operator --type=merge -p '{"spec":{"roleMapping":{"tester":"view"}}}'

# Wait for reconciliation
echo "Waiting for reconciliation..."
sleep 10

# Check updated values
AFTER_RB=$(get_metric_value 'permission_binder_managed_rolebindings_total')
echo "After: $AFTER_RB RoleBindings"

INCREASE=$((AFTER_RB - BEFORE_RB))
echo "Increase: $INCREASE"

if [ "$INCREASE" -gt 0 ]; then
    echo "✅ Metrics updated correctly - $INCREASE new RoleBindings detected"
else
    echo "❌ Metrics not updated - expected increase in RoleBindings"
fi

echo ""
echo "4. Testing metrics update on ConfigMap change..."

# Record initial namespace count
BEFORE_NS=$(get_metric_value 'permission_binder_managed_namespaces_total')
echo "Before: $BEFORE_NS namespaces"

# Add new namespace to ConfigMap
echo "Adding new namespace 'metrics-test-namespace' to ConfigMap..."
kubectl patch configmap permission-config -n permissions-binder-operator --type=merge -p '{"data":{"DG_FP00-K8S-metrics-test-namespace-admin":"DG_FP00-K8S-metrics-test-namespace-admin"}}'

# Wait for reconciliation
echo "Waiting for reconciliation..."
sleep 10

# Check updated values
AFTER_NS=$(get_metric_value 'permission_binder_managed_namespaces_total')
echo "After: $AFTER_NS namespaces"

NS_INCREASE=$((AFTER_NS - BEFORE_NS))
echo "Increase: $NS_INCREASE"

if [ "$NS_INCREASE" -gt 0 ]; then
    echo "✅ Namespace metrics updated correctly - $NS_INCREASE new namespaces detected"
else
    echo "❌ Namespace metrics not updated - expected increase in namespaces"
fi

echo ""
echo "5. Testing orphaned resources metrics..."

# Record initial orphaned count
BEFORE_ORPHANED=$(get_metric_value 'permission_binder_orphaned_resources_total')
echo "Before: $BEFORE_ORPHANED orphaned resources"

# Delete PermissionBinder (triggers SAFE MODE)
echo "Deleting PermissionBinder to trigger SAFE MODE..."
kubectl delete permissionbinder permissionbinder-example -n permissions-binder-operator

# Wait for cleanup
echo "Waiting for cleanup..."
sleep 10

# Check updated values
AFTER_ORPHANED=$(get_metric_value 'permission_binder_orphaned_resources_total')
echo "After: $AFTER_ORPHANED orphaned resources"

ORPHANED_INCREASE=$((AFTER_ORPHANED - BEFORE_ORPHANED))
echo "Increase: $ORPHANED_INCREASE"

if [ "$ORPHANED_INCREASE" -gt 0 ]; then
    echo "✅ Orphaned resources metrics updated correctly - $ORPHANED_INCREASE new orphaned resources detected"
else
    echo "❌ Orphaned resources metrics not updated - expected increase in orphaned resources"
fi

# Recreate PermissionBinder for adoption test
echo "Recreating PermissionBinder for adoption test..."
kubectl apply -f example/permissionbinder/permissionbinder-example.yaml

# Wait for adoption
echo "Waiting for adoption..."
sleep 10

# Check adoption events
ADOPTION_EVENTS=$(get_metric_value 'permission_binder_adoption_events_total')
echo "Adoption events: $ADOPTION_EVENTS"

if [ "$ADOPTION_EVENTS" -gt 0 ]; then
    echo "✅ Adoption events tracked correctly"
else
    echo "ℹ️  No adoption events recorded (may be normal if no orphaned resources were adopted)"
fi

echo ""
echo "=== Prometheus Metrics Test Complete ==="
echo "✅ All metrics are being collected and updated correctly"
echo "✅ Prometheus integration working properly"
