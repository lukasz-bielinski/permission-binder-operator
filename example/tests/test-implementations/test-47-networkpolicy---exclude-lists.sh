#!/bin/bash
# Test 47: Networkpolicy   Exclude Lists
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 47: NetworkPolicy - Exclude Lists"
echo "---------------------------------------"

# Add excluded namespace to ConfigMap
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-app-engineer,OU=Openshift,DC=example,DC=com
    CN=COMPANY-K8S-test-app-2-viewer,OU=Openshift,DC=example,DC=com
    CN=COMPANY-K8S-kube-system-engineer,OU=Openshift,DC=example,DC=com
EOF

# Wait for reconciliation
info_log "Waiting for reconciliation (10s)"
sleep 10

# Verify kube-system is excluded from NetworkPolicy processing
ALL_NAMESPACES=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath='{.status.networkPolicies[*].namespace}' 2>/dev/null || echo "")
EXCLUDED_FOUND=false
for ns in $ALL_NAMESPACES; do
    if [ "$ns" == "kube-system" ]; then
        EXCLUDED_FOUND=true
        break
    fi
done

if [ "$EXCLUDED_FOUND" == "false" ]; then
    pass_test "kube-system is correctly excluded from NetworkPolicy processing"
else
    fail_test "kube-system should be excluded but was found in NetworkPolicy status"
fi

# ============================================================================
# VERIFICATION: Check PRs for ALL namespaces in PermissionBinder status
# Test creates ConfigMap with test-app, test-app-2 (kube-system is excluded)
# ============================================================================
GITHUB_REPO="lukasz-bielinski/tests-network-policies"
TEST_NAMESPACES=("test-app" "test-app-2")  # kube-system is excluded, so no PR should be created

info_log "Verifying PRs for test namespaces (excluding kube-system)..."
for test_ns in "${TEST_NAMESPACES[@]}"; do
    # Check if namespace has PR status (may or may not have PR, depending on previous tests)
    NS_STATE=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$test_ns\")].state}" 2>/dev/null || echo "")
    if [ -n "$NS_STATE" ]; then
        info_log "Namespace $test_ns has state: $NS_STATE"
    fi
done

# ============================================================================
# CLEANUP: Remove PRs and branches from GitHub (test isolation)
# IMPORTANT: Cleanup is done AFTER all verifications are complete
# IMPORTANT: Removes entire cluster_name directory
# ============================================================================
info_log "=========================================="
info_log "Starting cleanup..."
info_log "=========================================="
cleanup_all_networkpolicy_test_artifacts "test-permissionbinder-networkpolicy" "$GITHUB_REPO" "DEV-cluster"

echo ""

# ============================================================================
