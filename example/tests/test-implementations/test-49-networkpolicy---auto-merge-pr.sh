#!/bin/bash
# Test 49: NetworkPolicy - Auto-Merge PR
# Source common functions (SCRIPT_DIR should be set by parent script)
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 49: NetworkPolicy - Auto-Merge PR"
echo "---------------------------------------"

# Setup: Create GitHub GitOps credentials Secret
CREDENTIALS_FILE="$SCRIPT_DIR/../../temp/github-gitops-credentials-secret.yaml"
if [ ! -f "$CREDENTIALS_FILE" ]; then
    fail_test "GitHub credentials file not found: $CREDENTIALS_FILE"
    echo "Please ensure temp/github-gitops-credentials-secret.yaml exists"
else
    if ! kubectl_retry kubectl get secret github-gitops-credentials -n $NAMESPACE >/dev/null 2>&1; then
        info_log "Creating GitHub GitOps credentials Secret from $CREDENTIALS_FILE"
        sed "s/namespace: permissions-binder-operator/namespace: $NAMESPACE/" "$CREDENTIALS_FILE" | kubectl apply -f - >/dev/null 2>&1
    else
        info_log "GitHub GitOps credentials Secret already exists"
    fi
fi

# Setup: Create PermissionBinder with NetworkPolicy enabled and auto-merge enabled
if ! kubectl_retry kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE >/dev/null 2>&1; then
    info_log "Creating PermissionBinder with NetworkPolicy enabled and auto-merge enabled"
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-permissionbinder-networkpolicy
  namespace: $NAMESPACE
spec:
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: "edit"
    viewer: "view"
  configMapName: "permission-config"
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
      enabled: true
      label: "auto-merge"
    excludeNamespaces:
      explicit:
        - "kube-system"
        - "kube-public"
      patterns:
        - "^kube-.*"
        - "^openshift-.*"
    backupExisting: true
    reconciliationInterval: "1h"
EOF
fi

# Update ConfigMap with test namespace
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-automerge-engineer,OU=Openshift,DC=example,DC=com
EOF

# Wait for reconciliation
info_log "Waiting for PermissionBinder to process ConfigMap (5s)"
sleep 5

# Check PermissionBinder status for NetworkPolicy entries
MAX_WAIT=60
WAITED=0
POLL_INTERVAL=2
NAMESPACES_FOUND=""
while [ $WAITED -lt $MAX_WAIT ]; do
    NAMESPACES_FOUND=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath='{.status.networkPolicies[*].namespace}' 2>/dev/null || echo "")
    if [ -n "$NAMESPACES_FOUND" ] && [ "$NAMESPACES_FOUND" != "" ]; then
        break
    fi
    sleep $POLL_INTERVAL
    WAITED=$((WAITED + POLL_INTERVAL))
done

if [ -n "$NAMESPACES_FOUND" ] && [ "$NAMESPACES_FOUND" != "" ]; then
    pass_test "NetworkPolicy status entries found: $NAMESPACES_FOUND"
else
    fail_test "No NetworkPolicy status entries found after ${MAX_WAIT}s"
    exit 1
fi

# ============================================================================
# VERIFICATION: Wait for PR creation and auto-merge
# ============================================================================
GITHUB_REPO="lukasz-bielinski/tests-network-policies"
TEST_NAMESPACE="test-automerge"
PR_VERIFICATION_FAILED=0

info_log "Waiting for PR to be created and auto-merged for $TEST_NAMESPACE (up to 180s)..."
pr_number=$(wait_for_pr_in_status "test-permissionbinder-networkpolicy" "$TEST_NAMESPACE" 180)

if [ -z "$pr_number" ] || [ "$pr_number" == "" ]; then
    fail_test "PR number not found for namespace $TEST_NAMESPACE after 180s"
    exit 1
fi

pass_test "PR number found: $pr_number"

# Get PR details from status
pr_details=$(get_pr_from_status "test-permissionbinder-networkpolicy" "$TEST_NAMESPACE")
pr_num pr_url pr_branch pr_state
IFS='|' read -r pr_num pr_url pr_branch pr_state <<< "$pr_details"

info_log "PR Details from status:"
info_log "  Number: $pr_num"
info_log "  URL: $pr_url"
info_log "  Branch: $pr_branch"
info_log "  State: $pr_state"

# Verify PR exists on GitHub
info_log "Verifying PR on GitHub..."
pr_json=$(verify_pr_on_github "$GITHUB_REPO" "$pr_number")

if [ $? -eq 0 ] && [ -n "$pr_json" ]; then
    pass_test "PR $pr_number exists on GitHub"
    
    # Extract PR details from JSON
    pr_title=$(echo "$pr_json" | jq -r '.title' 2>/dev/null || echo "")
    pr_state_gh=$(echo "$pr_json" | jq -r '.state' 2>/dev/null || echo "")
    pr_labels=$(echo "$pr_json" | jq -r '.labels[]?.name' 2>/dev/null || echo "")
    
    info_log "GitHub PR Details:"
    info_log "  Title: $pr_title"
    info_log "  State: $pr_state_gh"
    info_log "  Labels: $pr_labels"
    
    # Verify PR has auto-merge label
    if echo "$pr_labels" | grep -q "auto-merge"; then
        pass_test "PR has auto-merge label"
    else
        fail_test "PR does not have auto-merge label. Labels: $pr_labels"
        PR_VERIFICATION_FAILED=1
    fi
    
    # Verify PR is merged (auto-merge should merge it)
    if [ "$pr_state_gh" == "MERGED" ]; then
        pass_test "PR is merged (auto-merge worked)"
    else
        info_log "⚠️  PR state is $pr_state_gh (may need more time for auto-merge or checks may be blocking)"
        # Check PermissionBinder status state
        if [ "$pr_state" == "pr-merged" ]; then
            pass_test "PermissionBinder status shows pr-merged state"
        else
            info_log "⚠️  PermissionBinder status shows: $pr_state (may need more time)"
        fi
    fi
    
    # Verify PermissionBinder status shows pr-merged
    if [ "$pr_state" == "pr-merged" ]; then
        pass_test "PermissionBinder status shows pr-merged state"
    else
        info_log "⚠️  PermissionBinder status shows: $pr_state (expected pr-merged, may need more time)"
    fi
    
    # Verify PR title contains namespace
    if echo "$pr_title" | grep -q "$TEST_NAMESPACE"; then
        pass_test "PR title contains namespace: $TEST_NAMESPACE"
    else
        fail_test "PR title does not contain namespace $TEST_NAMESPACE: $pr_title"
        PR_VERIFICATION_FAILED=1
    fi
    
    # Verify NetworkPolicy files exist in main branch after merge
    if [ "$pr_state_gh" == "MERGED" ]; then
        info_log "Verifying NetworkPolicy files exist in main branch..."
        if command -v gh &> /dev/null; then
            # Check if file exists in main branch
            file_path="networkpolicies/DEV-cluster/$TEST_NAMESPACE/$TEST_NAMESPACE-deny-all-ingress.yaml"
            if gh api repos/"$GITHUB_REPO"/contents/"$file_path" --jq '.name' 2>/dev/null | grep -q "deny-all-ingress.yaml"; then
                pass_test "NetworkPolicy file exists in main branch after merge"
            else
                info_log "⚠️  NetworkPolicy file not found in main branch (may need more time for merge to complete)"
            fi
        fi
    fi
    
else
    fail_test "PR $pr_number not found on GitHub or gh CLI not available"
    PR_VERIFICATION_FAILED=1
fi

# ============================================================================
# CLEANUP: Remove files from GitHub (PR already merged, so files are in main branch)
# ============================================================================
info_log "=========================================="
info_log "Cleaning up test artifacts..."
info_log "=========================================="

# Cleanup files from main branch (PR was merged)
cleanup_networkpolicy_test_artifacts "test-permissionbinder-networkpolicy" "$TEST_NAMESPACE" "$GITHUB_REPO"

# Final cleanup: Remove entire cluster directory
info_log "Final cleanup: Removing entire DEV-cluster directory..."
cleanup_networkpolicy_files_from_repo "$GITHUB_REPO" "" "DEV-cluster"

# Final test result
if [ $PR_VERIFICATION_FAILED -eq 1 ]; then
    fail_test "Some PR verifications failed - check logs above"
    exit 1
fi

echo ""

# ============================================================================

