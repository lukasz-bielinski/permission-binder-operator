#!/bin/bash
# Test 46: Networkpolicy   Drift Detection
#
# Self-contained under the first-owner-wins ownership gate (issues #45/#59):
# provisions its OWN PermissionBinder + ConfigMap resolving to a DEDICATED
# namespace. Previously this test only read the PermissionBinder created by
# earlier NP tests, which does not exist under full isolation (per-test
# cleanup runs before every test) - all assertions were vacuous.
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

BINDER_NAME="test-permissionbinder-networkpolicy-drift"
CONFIGMAP_NAME="np-test-config-46"
# Dedicated namespace (prefix empty in legacy single-instance mode; name
# contains "test-" so both cleanup sweeps catch it)
TEST_NAMESPACE="${TEST_NS_PREFIX}np-test-46"
GITHUB_REPO="lukasz-bielinski/tests-network-policies"

# ============================================================================
# ============================================================================
echo ""
echo "Test 46: NetworkPolicy - Drift Detection"
echo "-----------------------------------------"

cleanup_resources() {
    # Delete the PB FIRST: with a 10s reconciliationInterval the operator
    # could otherwise recreate the PR between artifact cleanup and PB removal.
    # cleanup_networkpolicy_test_artifacts falls back to a branch-name lookup
    # on GitHub when the PB status is gone.
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
# 2. Create PermissionBinder with a short reconciliation interval so the
#    periodic (drift-detection) reconciliation actually runs during the test
# ----------------------------------------------------------------------------
info_log "Creating PermissionBinder $BINDER_NAME with reconciliationInterval=10s"
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
# 3. Wait for the periodic reconciliation timestamp
# ----------------------------------------------------------------------------
info_log "Waiting for periodic reconciliation (up to 90s)"
MAX_WAIT=90
WAITED=0
RECONCILIATION_TIME=""
while [ $WAITED -lt $MAX_WAIT ]; do
    RECONCILIATION_TIME=$(kubectl get permissionbinder "$BINDER_NAME" -n $NAMESPACE -o jsonpath='{.status.lastNetworkPolicyReconciliation}' 2>/dev/null || echo "")
    if [ -n "$RECONCILIATION_TIME" ] && [ "$RECONCILIATION_TIME" != "" ]; then
        break
    fi
    sleep 10
    WAITED=$((WAITED + 10))
done

if [ -n "$RECONCILIATION_TIME" ] && [ "$RECONCILIATION_TIME" != "" ]; then
    pass_test "Periodic reconciliation timestamp found: $RECONCILIATION_TIME"
else
    fail_test "Periodic reconciliation timestamp not set within ${MAX_WAIT}s (reconciliationInterval: 10s)"
fi

# ============================================================================
# VERIFICATION: Check namespaces tracked in PermissionBinder status
# This test verifies the periodic reconciliation loop, not PR creation;
# the PR created for $TEST_NAMESPACE is cleaned up by the EXIT trap.
# ============================================================================
ALL_NAMESPACES=$(kubectl get permissionbinder "$BINDER_NAME" -n $NAMESPACE -o jsonpath='{.status.networkPolicies[*].namespace}' 2>/dev/null || echo "")

if [ -n "$ALL_NAMESPACES" ] && [ "$ALL_NAMESPACES" != "" ]; then
    info_log "Found namespaces with NetworkPolicy status: $ALL_NAMESPACES"
    info_log "Note: This test verifies periodic reconciliation, not PR creation"
else
    info_log "No namespaces found in NetworkPolicy status (may be normal if no PRs were created yet)"
fi

# Cleanup handled by trap
echo ""

# ============================================================================
