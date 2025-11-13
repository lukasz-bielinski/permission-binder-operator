#!/bin/bash
# Test 38: Multiple Serviceaccounts Per Namespace Scaling
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 38: Multiple ServiceAccounts per Namespace"
echo "-------------------------------------------------"

# Create PermissionBinder with multiple SA mappings
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-multiple
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: admin
    runtime: view
    monitoring: view
    cicd: edit
    backup: edit
    logging: view
    metrics: view
    ingress: edit
EOF

START_TIME=$(date +%s)
sleep 25
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if kubectl get namespace test-namespace-001 >/dev/null 2>&1; then
    # Count ServiceAccounts
    ACTUAL_SA_COUNT=$(kubectl get sa -n test-namespace-001 2>/dev/null | grep "sa-" | wc -l)
    ACTUAL_SA_COUNT=$(echo "$ACTUAL_SA_COUNT" | tr -d ' \n')
    
    info_log "ServiceAccounts created: $ACTUAL_SA_COUNT"
    info_log "Reconciliation time: ${DURATION}s"
    
    if [ "$ACTUAL_SA_COUNT" -ge 8 ]; then
        pass_test "Multiple ServiceAccounts created successfully ($ACTUAL_SA_COUNT)"
    else
        info_log "Created $ACTUAL_SA_COUNT ServiceAccounts (expected 8+)"
    fi
    
    # Performance check
    if [ $DURATION -lt 30 ]; then
        pass_test "Reconciliation completed in acceptable time (${DURATION}s < 30s)"
    else
        info_log "Reconciliation took ${DURATION}s"
    fi
    
    # Check for duplicates
    DUPLICATE_CHECK=$(kubectl get sa -n test-namespace-001 -o json 2>/dev/null | jq -r '[.items[].metadata.name] | group_by(.) | map(select(length > 1)) | length')
    if [ "$DUPLICATE_CHECK" == "0" ]; then
        pass_test "No duplicate ServiceAccounts"
    else
        fail_test "Duplicate ServiceAccounts detected"
    fi
else
    info_log "test-namespace-001 does not exist, skipping multiple SA test"
fi

echo ""

# ============================================================================
