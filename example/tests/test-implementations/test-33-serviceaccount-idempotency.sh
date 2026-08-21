#!/bin/bash
# Test 33: Serviceaccount Idempotency
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# Per-instance test namespace (prefix empty in legacy single-instance mode)
TEST_NS="${TEST_NS_PREFIX}test-namespace-001"

# ============================================================================
# ============================================================================
echo "Test 33: ServiceAccount Idempotency"
echo "-------------------------------------"

# Record SA UID if it exists
if kubectl get namespace "$TEST_NS" >/dev/null 2>&1; then
    if kubectl get sa ${TEST_NS}-sa-deploy -n "$TEST_NS" >/dev/null 2>&1; then
        SA_UID=$(kubectl get sa ${TEST_NS}-sa-deploy -n "$TEST_NS" -o jsonpath='{.metadata.uid}')
        
        # Trigger reconciliation
        kubectl annotate configmap permission-config -n $NAMESPACE test-reconcile="$(date +%s)" --overwrite >/dev/null 2>&1
        sleep 10
        
        # Check if UID changed
        NEW_SA_UID=$(kubectl get sa ${TEST_NS}-sa-deploy -n "$TEST_NS" -o jsonpath='{.metadata.uid}')
        
        if [ "$SA_UID" == "$NEW_SA_UID" ]; then
            pass_test "ServiceAccount not recreated (idempotent)"
        else
            fail_test "ServiceAccount was recreated (UID changed)"
        fi
    else
        info_log "ServiceAccount ${TEST_NS}-sa-deploy not found for idempotency test"
    fi
else
    info_log "$TEST_NS does not exist, skipping idempotency test"
fi

echo ""

# ============================================================================
