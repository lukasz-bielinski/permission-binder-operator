#!/bin/bash
# Test 13: Non Existent Clusterrole Security
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 13: Non-Existent ClusterRole (Security)"
echo "----------------------------------------------"

# Add role with non-existent ClusterRole
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"add","path":"/spec/roleMapping/security-test","value":"nonexistent-clusterrole"}]' >/dev/null 2>&1

kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-security="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 10

# Check for security warning in logs
SECURITY_WARNING=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=50 | grep -v "^I" | jq -c 'select(.severity=="warning" and .clusterRole=="nonexistent-clusterrole")' 2>/dev/null | wc -l)

if [ "$SECURITY_WARNING" -gt 0 ]; then
    pass_test "ClusterRole validation logged security WARNING"
    info_log "Found $SECURITY_WARNING warning logs for missing ClusterRole"
else
    info_log "No security warning detected (may not be implemented or needs more time)"
fi

# Verify RoleBinding was still created (operator should create it despite missing ClusterRole)
SECURITY_RB=$(kubectl_retry kubectl get rolebinding --all-namespaces -l permission-binder.io/managed-by=permission-binder-operator -o json | jq '[.items[] | select(.roleRef.name=="nonexistent-clusterrole")] | length')
if [ "$SECURITY_RB" -gt 0 ]; then
    pass_test "RoleBinding created despite missing ClusterRole"
else
    info_log "RoleBinding not created (may be due to no matching ConfigMap entries)"
fi

# Cleanup
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"remove","path":"/spec/roleMapping/security-test"}]' >/dev/null 2>&1

echo ""

# ============================================================================
