#!/bin/bash
# Test 54: NetworkPolicy - PR State Transitions
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 54: NetworkPolicy - PR State Transitions"
echo "---------------------------------------------"

BINDER_NAME="test-permissionbinder-networkpolicy-state"
CONFIGMAP_NAME="permission-config-state"
TEST_NAMESPACE="test-state-transitions"
GITHUB_REPO="lukasz-bielinski/tests-network-policies"

if ! command -v gh &> /dev/null; then
    fail_test "gh CLI is required for this test (PR merging)"
    exit 1
fi

# Cleanup helper
cleanup_resources() {
    cleanup_networkpolicy_test_artifacts "$BINDER_NAME" "$TEST_NAMESPACE" "$GITHUB_REPO" 2>/dev/null || true
    kubectl delete permissionbinder "$BINDER_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    kubectl delete configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
}

trap cleanup_resources EXIT

# ----------------------------------------------------------------------------
# 1. Ensure GitHub credentials Secret exists
# ----------------------------------------------------------------------------
CREDENTIALS_FILE="$SCRIPT_DIR/../../temp/github-gitops-credentials-secret.yaml"
if [ ! -f "$CREDENTIALS_FILE" ]; then
    fail_test "GitHub credentials file not found: $CREDENTIALS_FILE"
    exit 1
fi

if ! kubectl_retry kubectl get secret github-gitops-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
    info_log "Creating GitHub credentials Secret from $CREDENTIALS_FILE"
    sed "s/namespace: permissions-binder-operator/namespace: $NAMESPACE/" "$CREDENTIALS_FILE" | kubectl apply -f - >/dev/null 2>&1
fi

# ----------------------------------------------------------------------------
# 2. Create PermissionBinder with NetworkPolicy auto-merge disabled
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
    reconciliationInterval: "1h"
EOF

# ----------------------------------------------------------------------------
# 3. Create ConfigMap to trigger reconciliation
# ----------------------------------------------------------------------------
info_log "Creating ConfigMap $CONFIGMAP_NAME"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIGMAP_NAME
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-$TEST_NAMESPACE-engineer,OU=Openshift,DC=example,DC=com
EOF

info_log "Waiting for reconciliation (15s)"
sleep 15

# ----------------------------------------------------------------------------
# 4. Wait for PR creation and capture initial state
# ----------------------------------------------------------------------------
PR_NUMBER=$(wait_for_pr_in_status "$BINDER_NAME" "$TEST_NAMESPACE" 150)
if [ -z "$PR_NUMBER" ]; then
    fail_test "PR number not found for namespace $TEST_NAMESPACE"
    exit 1
fi

INITIAL_STATE=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.networkPolicies[?(@.namespace=="'$TEST_NAMESPACE'")].state}' 2>/dev/null || echo "")
pass_test "PR created (number: $PR_NUMBER, initial state: ${INITIAL_STATE:-unknown})"

# ----------------------------------------------------------------------------
# 5. Merge PR using gh CLI
# ----------------------------------------------------------------------------
info_log "Merging PR $PR_NUMBER via gh CLI"
if ! gh pr merge "$PR_NUMBER" --repo "$GITHUB_REPO" --merge --admin >/dev/null 2>&1; then
    info_log "⚠️  gh pr merge failed (perhaps already merged); attempting status check"
else
    pass_test "PR $PR_NUMBER merged via gh CLI"
fi

info_log "Waiting for operator to detect merged state (up to 120s)"
if wait_for_pr_state "$BINDER_NAME" "$TEST_NAMESPACE" "pr-merged" 120; then
    pass_test "PermissionBinder status transitioned to pr-merged"
else
    CURRENT_STATE=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.networkPolicies[?(@.namespace=="'$TEST_NAMESPACE'")].state}' 2>/dev/null || echo "")
    fail_test "Expected pr-merged state, current state: ${CURRENT_STATE:-unknown}"
fi

# ----------------------------------------------------------------------------
# 6. Output final PR details for audit
# ----------------------------------------------------------------------------
PR_DETAILS=$(get_pr_from_status "$BINDER_NAME" "$TEST_NAMESPACE")
IFS='|' read -r PR_NUM PR_URL PR_BRANCH PR_STATE <<< "$PR_DETAILS"
info_log "Final PR details: number=$PR_NUM, state=$PR_STATE, branch=$PR_BRANCH, url=$PR_URL"

# Cleanup handled by trap

echo ""

# ============================================================================
