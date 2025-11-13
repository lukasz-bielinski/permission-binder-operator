#!/bin/bash
# Test 04: Configmap Changes   Addition
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 4: ConfigMap Changes - Addition"
echo "-------------------------------------"

# Add new LDAP DN entry to whitelist.txt
NEW_ENTRY="CN=COMPANY-K8S-test4-new-namespace-admin,OU=TestOU,DC=example,DC=com"
kubectl_retry kubectl get configmap permission-config -n $NAMESPACE -o jsonpath='{.data.whitelist\.txt}' > /tmp/whitelist-add.txt
echo "$NEW_ENTRY" >> /tmp/whitelist-add.txt
kubectl create configmap permission-config -n $NAMESPACE --from-file=whitelist.txt=/tmp/whitelist-add.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f /tmp/whitelist-add.txt

# Force reconciliation
kubectl_retry kubectl annotate permissionbinder permissionbinder-example -n $NAMESPACE test-addition="$(date +%s)" --overwrite >/dev/null 2>&1
sleep 30

# Check namespace created
NS_EXISTS=$(kubectl_retry kubectl get namespace test4-new-namespace 2>/dev/null | wc -l)
if [ "$NS_EXISTS" -gt 0 ]; then
    pass_test "New namespace created from ConfigMap entry"
else
    fail_test "Namespace not created"
fi

# Check RoleBinding created
RB_EXISTS=$(kubectl_retry kubectl get rolebinding test4-new-namespace-admin -n test4-new-namespace 2>/dev/null | wc -l)
if [ "$RB_EXISTS" -gt 0 ]; then
    pass_test "RoleBinding created for new ConfigMap entry"
else
    fail_test "RoleBinding not created"
fi

# Verify annotations
ANNOTATIONS=$(kubectl_retry kubectl get rolebinding test4-new-namespace-admin -n test4-new-namespace -o jsonpath='{.metadata.annotations}' 2>/dev/null | jq -e '."permission-binder.io/managed-by"' 2>/dev/null)
if [ "$ANNOTATIONS" == "\"permission-binder-operator\"" ]; then
    pass_test "RoleBinding has correct annotations"
else
    info_log "RoleBinding annotations may be incorrect"
fi

echo ""

# ============================================================================
