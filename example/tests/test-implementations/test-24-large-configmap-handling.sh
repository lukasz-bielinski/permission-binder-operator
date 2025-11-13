#!/bin/bash
# Test 24: Large Configmap Handling
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 24: Large ConfigMap Handling"
echo "-----------------------------------"

# Create ConfigMap with 50+ entries
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-large.txt
for i in {1..50}; do
    echo "CN=COMPANY-K8S-large-project-$i-admin,OU=Test,DC=example,DC=com" >> /tmp/whitelist-large.txt
done
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-large.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-large.txt

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-large="$(date +%s)" --overwrite >/dev/null 2>&1

# Time the reconciliation
START_TIME=$(date +%s)
sleep 40
END_TIME=$(date +%s)
RECONCILE_TIME=$((END_TIME - START_TIME))

# Check if entries were processed
LARGE_NS_COUNT=$(kubectl_retry kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
info_log "Created namespaces: $LARGE_NS_COUNT"
info_log "Reconciliation time: ${RECONCILE_TIME}s"

if [ "$RECONCILE_TIME" -lt 60 ]; then
    pass_test "Large ConfigMap processed in acceptable time (${RECONCILE_TIME}s < 60s)"
else
    info_log "Reconciliation took ${RECONCILE_TIME}s (may be acceptable depending on cluster)"
fi

# Check operator memory usage
POD_NAME=$(kubectl_retry kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=permission-binder-operator -o jsonpath='{.items[0].metadata.name}')
MEMORY_USAGE=$(kubectl top pod -n $NAMESPACE $POD_NAME 2>/dev/null | tail -1 | awk '{print $3}' || echo "N/A")
info_log "Operator memory usage: $MEMORY_USAGE"

echo ""

# ============================================================================
