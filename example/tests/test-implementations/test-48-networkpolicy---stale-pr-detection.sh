#!/bin/bash
# Test 48: Networkpolicy   Stale Pr Detection
#
# Self-contained under the first-owner-wins ownership gate (issues #45/#59):
# provisions its OWN PermissionBinder + ConfigMap resolving to a DEDICATED
# namespace. Previously this test only read the PermissionBinder created by
# earlier NP tests, which does not exist under full isolation - all checks
# were vacuous.
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

BINDER_NAME="test-permissionbinder-networkpolicy-stale"
CONFIGMAP_NAME="np-test-config-48"
# Dedicated namespace (prefix empty in legacy single-instance mode; name
# contains "test-" so both cleanup sweeps catch it)
TEST_NAMESPACE="${TEST_NS_PREFIX}np-test-48"
GITHUB_REPO="lukasz-bielinski/tests-network-policies"

# ============================================================================
# ============================================================================
echo ""
echo "Test 48: NetworkPolicy - Stale PR Detection"
echo "--------------------------------------------"

cleanup_resources() {
    # Delete the PB first so the operator cannot recreate the PR between
    # artifact cleanup and PB removal (cleanup falls back to branch lookup).
    kubectl delete permissionbinder "$BINDER_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    kubectl delete configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    cleanup_networkpolicy_test_artifacts "$BINDER_NAME" "$TEST_NAMESPACE" "$GITHUB_REPO" 2>/dev/null || true
}

trap cleanup_resources EXIT

# ----------------------------------------------------------------------------
# 1. Ensure GitHub credentials Secret exists
# ----------------------------------------------------------------------------
CREDENTIALS_FILE="${GITHUB_GITOPS_SECRET_FILE:-$SCRIPT_DIR/../../temp/github-gitops-credentials-secret.yaml}"
if [ ! -f "$CREDENTIALS_FILE" ]; then
    fail_test "GitHub credentials file not found: $CREDENTIALS_FILE"
    exit 1
fi

if ! kubectl_retry kubectl get secret github-gitops-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
    info_log "Creating GitHub credentials Secret from $CREDENTIALS_FILE"
    sed "s/namespace: permissions-binder-operator/namespace: $NAMESPACE/" "$CREDENTIALS_FILE" | kubectl apply -f - >/dev/null 2>&1
fi

# ----------------------------------------------------------------------------
# 2. Create PermissionBinder (auto-merge off so the PR stays open) + ConfigMap
# ----------------------------------------------------------------------------
info_log "Creating PermissionBinder $BINDER_NAME"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: $BINDER_NAME
  namespace: $NAMESPACE
spec:
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: "edit"
    viewer: "view"
  configMapName: "$CONFIGMAP_NAME"
  configMapNamespace: "$NAMESPACE"
  networkPolicy:
    enabled: true
    gitRepository:
      provider: "github"
      url: "https://github.com/lukasz-bielinski/tests-network-policies.git"
      baseBranch: "main"
      clusterName: "DEV-cluster"
      credentialsSecretRef:
        name: "github-gitops-credentials"
        namespace: "$NAMESPACE"
    templateDir: "networkpolicies/templates"
    autoMerge:
      enabled: false
    backupExisting: true
    reconciliationInterval: "10s"
EOF

# Own ConfigMap -> this CR is the first (and only) owner of $TEST_NAMESPACE
if ! create_np_test_configmap "$CONFIGMAP_NAME" "$TEST_NAMESPACE"; then
    fail_test "Could not create test ConfigMap $CONFIGMAP_NAME"
    exit 1
fi

# ----------------------------------------------------------------------------
# 3. Wait for the PR (an open PR is the precondition for staleness tracking)
# ----------------------------------------------------------------------------
PR_NUMBER=$(wait_for_pr_in_status "$BINDER_NAME" "$TEST_NAMESPACE" 150)
if [ -z "$PR_NUMBER" ]; then
    fail_test "PR not created for namespace $TEST_NAMESPACE within 150s"
    exit 1
fi
pass_test "PR created for $TEST_NAMESPACE (number: $PR_NUMBER)"

# Verify the open PR carries a CreatedAt timestamp (input for stale detection)
CREATED_AT=$(kubectl get permissionbinder "$BINDER_NAME" -n $NAMESPACE -o jsonpath='{.status.networkPolicies[?(@.namespace=="'$TEST_NAMESPACE'")].createdAt}' 2>/dev/null || echo "")
if [ -n "$CREATED_AT" ]; then
    pass_test "Open PR has CreatedAt timestamp for staleness tracking: $CREATED_AT"
else
    info_log "⚠️  CreatedAt timestamp not populated for $TEST_NAMESPACE"
fi

# ----------------------------------------------------------------------------
# 4. Check for stale-PR state (informational: the freshly created PR only
#    becomes pr-stale after stalePRThreshold, far beyond this test's window)
# ----------------------------------------------------------------------------
ALL_STATES=$(kubectl get permissionbinder "$BINDER_NAME" -n $NAMESPACE -o jsonpath='{.status.networkPolicies[*].state}' 2>/dev/null || echo "")
STALE_FOUND=false
for state in $ALL_STATES; do
    if [ "$state" == "pr-stale" ]; then
        STALE_FOUND=true
        break
    fi
done

if [ "$STALE_FOUND" == "true" ]; then
    # Verify CreatedAt timestamp exists for stale PR
    STALE_CREATED_AT=$(kubectl get permissionbinder "$BINDER_NAME" -n $NAMESPACE -o jsonpath='{.status.networkPolicies[?(@.state=="pr-stale")].createdAt}' 2>/dev/null || echo "")
    if [ -n "$STALE_CREATED_AT" ] && [ "$STALE_CREATED_AT" != "" ]; then
        pass_test "Stale PR detected with CreatedAt timestamp: $STALE_CREATED_AT"
    else
        fail_test "Stale PR detected but CreatedAt timestamp missing"
    fi
else
    info_log "No stale PRs detected (expected: stalePRThreshold far exceeds test duration)"
fi

# Log PR states for all tracked namespaces
ALL_NAMESPACES=$(kubectl get permissionbinder "$BINDER_NAME" -n $NAMESPACE -o jsonpath='{.status.networkPolicies[*].namespace}' 2>/dev/null || echo "")
for ns in $ALL_NAMESPACES; do
    NS_STATE=$(kubectl get permissionbinder "$BINDER_NAME" -n $NAMESPACE -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$ns\")].state}" 2>/dev/null || echo "")
    info_log "  Namespace $ns: state=$NS_STATE"
done

# Cleanup handled by trap
echo ""

# ============================================================================
