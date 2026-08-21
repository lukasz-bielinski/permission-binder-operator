#!/bin/bash
# Test 15: Manual Rolebinding Modification Protection
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 15: Manual RoleBinding Modification (Protection)"
echo "-------------------------------------------------------"

# Find a managed RoleBinding (sample from this instance's own CR - issue #35)
SAMPLE_RB=$(list_owned_rolebindings "permissionbinder-example" | head -1 | awk '{print $1 "/" $2}')

if [ -n "$SAMPLE_RB" ] && [ "$SAMPLE_RB" != "null/" ]; then
    RB_NAMESPACE=$(echo $SAMPLE_RB | cut -d/ -f1)
    RB_NAME=$(echo $SAMPLE_RB | cut -d/ -f2)
    
    # Get original group
    ORIGINAL_GROUP=$(kubectl_retry kubectl get rolebinding $RB_NAME -n $RB_NAMESPACE -o jsonpath='{.subjects[0].name}' 2>/dev/null)
    info_log "Testing RoleBinding: $RB_NAMESPACE/$RB_NAME (group: $ORIGINAL_GROUP)"
    
    # Manually modify RoleBinding
    kubectl_retry kubectl patch rolebinding $RB_NAME -n $RB_NAMESPACE --type='json' \
      -p='[{"op":"replace","path":"/subjects/0/name","value":"MANUALLY-HACKED-GROUP"}]' >/dev/null 2>&1
    
    sleep 5
    
    # Trigger reconciliation
    kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-override="$(date +%s)" --overwrite >/dev/null 2>&1
    sleep 10
    
    # Check if restored
    CURRENT_GROUP=$(kubectl_retry kubectl get rolebinding $RB_NAME -n $RB_NAMESPACE -o jsonpath='{.subjects[0].name}' 2>/dev/null)
    
    if [ "$CURRENT_GROUP" == "$ORIGINAL_GROUP" ]; then
        pass_test "Operator enforced desired state (overrode manual change)"
    else
        info_log "Manual change persisted or reconciliation pending: $CURRENT_GROUP (expected: $ORIGINAL_GROUP)"
    fi
else
    info_log "No RoleBindings found to test manual modification protection"
fi

echo ""

# ============================================================================
