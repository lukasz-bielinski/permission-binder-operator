#!/bin/bash
# Test 54: NetworkPolicy - PR State Transitions
#
# The test-side flow is correct: reconciliationInterval=10s plus ConfigMap
# nudges (the operator has NO timer-driven requeue, so reconciles only happen
# on events). KNOWN EXPECTED FAILURE until the operator gains a
# pending->merged refresh: as of v1.8.x no code path transitions a
# pr-pending entry to pr-merged for an externally merged PR - the periodic
# pass only processes entries already in pr-merged (drift/template/stale),
# the event-driven pass skips namespaces with a pr-pending entry, and
# pr-merged is only ever set at creation time by immediate auto-merge
# (verified live + at code level in issue #59). The pr-merged assertion
# below goes green as soon as that operator gap is fixed.
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
# Dedicated namespace (prefix empty in legacy single-instance mode; name
# contains "test-" so both cleanup sweeps catch it)
TEST_NAMESPACE="${TEST_NS_PREFIX}np-test-54"
GITHUB_REPO="lukasz-bielinski/tests-network-policies"

if ! command -v gh &> /dev/null; then
    fail_test "gh CLI is required for this test (PR merging)"
    exit 1
fi

# Cleanup helper
cleanup_resources() {
    # Delete the PB first: with a 10s reconciliationInterval the operator
    # could otherwise recreate artifacts between cleanup and PB removal
    # (cleanup falls back to a branch-name lookup when the status is gone).
    kubectl delete permissionbinder "$BINDER_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    kubectl delete configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    cleanup_networkpolicy_test_artifacts "$BINDER_NAME" "$TEST_NAMESPACE" "$GITHUB_REPO" 2>/dev/null || true
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
# 2. Create PermissionBinder with NetworkPolicy auto-merge disabled and a
#    short reconciliationInterval (PR-state refresh is periodic-only)
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
if ! np_gh pr merge "$PR_NUMBER" --repo "$GITHUB_REPO" --merge --admin >/dev/null 2>&1; then
    info_log "⚠️  gh pr merge failed (perhaps already merged); attempting status check"
else
    pass_test "PR $PR_NUMBER merged via gh CLI"
fi

# The merge happened on GitHub only - no Kubernetes event fires, so nudge
# reconciliation with ConfigMap-annotation touches. NOTE: this makes the
# refresh OBSERVABLE but cannot make it happen - the operator currently has
# no pending->merged refresh path (see header); the assertion stays red
# until that operator gap is fixed.
info_log "Waiting for operator to detect merged state (up to 120s, nudging reconciliation every 15s)"
MERGED_RECORDED=false
for attempt in $(seq 1 8); do
    touch_np_configmap "$CONFIGMAP_NAME"
    if wait_for_pr_state "$BINDER_NAME" "$TEST_NAMESPACE" "pr-merged" 15; then
        MERGED_RECORDED=true
        break
    fi
done
if [ "$MERGED_RECORDED" = "true" ]; then
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
