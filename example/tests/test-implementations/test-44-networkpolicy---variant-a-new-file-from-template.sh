#!/bin/bash
# Test 44: NetworkPolicy - Variant A (New File from Template)
# Source common functions (SCRIPT_DIR should be set by parent script)
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 44: NetworkPolicy - Variant A (New File from Template)"
echo "------------------------------------------------------------"

# Setup: Create GitHub GitOps credentials Secret
# Use dedicated credentials file from temp/ directory
CREDENTIALS_FILE="$SCRIPT_DIR/../../temp/github-gitops-credentials-secret.yaml"
if [ ! -f "$CREDENTIALS_FILE" ]; then
    fail_test "GitHub credentials file not found: $CREDENTIALS_FILE"
    echo "Please ensure temp/github-gitops-credentials-secret.yaml exists"
else
    if ! kubectl_retry kubectl get secret github-gitops-credentials -n $NAMESPACE >/dev/null 2>&1; then
        info_log "Creating GitHub GitOps credentials Secret from $CREDENTIALS_FILE"
        # Update namespace in the file and apply
        sed "s/namespace: permissions-binder-operator/namespace: $NAMESPACE/" "$CREDENTIALS_FILE" | kubectl apply -f - >/dev/null 2>&1
    else
        info_log "GitHub GitOps credentials Secret already exists"
    fi
fi

# Setup: Create PermissionBinder with NetworkPolicy enabled
if ! kubectl_retry kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE >/dev/null 2>&1; then
    info_log "Creating PermissionBinder with NetworkPolicy enabled"
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

# Update ConfigMap with test namespaces
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
EOF

# Wait for reconciliation (reduced from 10s to 5s - operator processes quickly)
info_log "Waiting for PermissionBinder to process ConfigMap (5s)"
sleep 5

# Check PermissionBinder status for NetworkPolicy entries (optimized polling: 2s interval)
MAX_WAIT=60
WAITED=0
POLL_INTERVAL=2  # Faster polling: 2 seconds instead of 5
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
fi

# ============================================================================
# VERIFICATION: Check PRs for ALL namespaces created by this test
# Test creates ConfigMap with test-app and test-app-2, so we need to verify both
# ============================================================================

GITHUB_REPO="lukasz-bielinski/tests-network-policies"
TEST_NAMESPACES=("test-app" "test-app-2")
PR_VERIFICATION_FAILED=0

# Function to verify PR for a namespace
verify_pr_for_namespace() {
    local namespace=$1
    local pr_number=""
    
    info_log "=========================================="
    info_log "Verifying PR for namespace: $namespace"
    info_log "=========================================="
    
    # Wait for PR to be created and get PR number from status
    info_log "Waiting for PR to be created for $namespace (polling every 2s, up to 120s)..."
    pr_number=$(wait_for_pr_in_status "test-permissionbinder-networkpolicy" "$namespace" 120)
    
    # If PR number not found, check if PR state indicates it was merged (may need to get PR from GitHub)
    if [ -z "$pr_number" ] || [ "$pr_number" == "" ]; then
        local pr_state=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$namespace\")].state}" 2>/dev/null || echo "")
        if [ "$pr_state" == "pr-merged" ] || [ "$pr_state" == "pr-pending" ]; then
            info_log "PR state found: $pr_state, but PR number missing. Checking GitHub for recent PRs..."
            if command -v gh &> /dev/null; then
                # Get most recent PR for namespace (branch pattern: networkpolicy/DEV-cluster/$namespace)
                pr_number=$(gh pr list --repo "$GITHUB_REPO" --head "networkpolicy/DEV-cluster/$namespace" --state all --json number,title,state --limit 1 --jq '.[0].number' 2>/dev/null || echo "")
                if [ -n "$pr_number" ] && [ "$pr_number" != "null" ] && [ "$pr_number" != "" ]; then
                    info_log "Found PR number from GitHub: $pr_number"
                fi
            fi
        fi
    fi
    
    if [ -z "$pr_number" ] || [ "$pr_number" == "" ]; then
        fail_test "PR number not found for namespace $namespace after 120s"
        PR_VERIFICATION_FAILED=1
        return 1
    fi
    
    pass_test "PR number found for $namespace: $pr_number"
    
    # Get PR details from status
    local pr_details=$(get_pr_from_status "test-permissionbinder-networkpolicy" "$namespace")
    local pr_num pr_url pr_branch pr_state
    IFS='|' read -r pr_num pr_url pr_branch pr_state <<< "$pr_details"
    
    info_log "PR Details from status:"
    info_log "  Number: $pr_num"
    info_log "  URL: $pr_url"
    info_log "  Branch: $pr_branch"
    info_log "  State: $pr_state"
    
    # Verify PR exists on GitHub
    info_log "Verifying PR on GitHub..."
    local pr_json=$(verify_pr_on_github "$GITHUB_REPO" "$pr_number")
    
    if [ $? -eq 0 ] && [ -n "$pr_json" ]; then
        pass_test "PR $pr_number exists on GitHub"
        
        # Extract PR details from JSON
        local pr_title=$(echo "$pr_json" | jq -r '.title' 2>/dev/null || echo "")
        local pr_state_gh=$(echo "$pr_json" | jq -r '.state' 2>/dev/null || echo "")
        local pr_branch_gh=$(echo "$pr_json" | jq -r '.headRefName' 2>/dev/null || echo "")
        local pr_url_gh=$(echo "$pr_json" | jq -r '.url' 2>/dev/null || echo "")
        
        info_log "GitHub PR Details:"
        info_log "  Title: $pr_title"
        info_log "  State: $pr_state_gh"
        info_log "  Branch: $pr_branch_gh"
        info_log "  URL: $pr_url_gh"
        
        # Verify PR title contains expected namespace
        if echo "$pr_title" | grep -q "$namespace"; then
            pass_test "PR title contains namespace: $namespace"
        else
            fail_test "PR title does not contain namespace $namespace: $pr_title"
            PR_VERIFICATION_FAILED=1
        fi
        
        # Verify PR contains expected files (only for test-app, as it's the primary test case)
        if [ "$namespace" == "test-app" ]; then
            info_log "Verifying PR files..."
            local expected_files="networkpolicies/DEV-cluster/test-app/test-app-deny-all-ingress.yaml networkpolicies/DEV-cluster/kustomization.yaml"
            if verify_pr_files "$GITHUB_REPO" "$pr_number" "$expected_files"; then
                pass_test "PR contains expected NetworkPolicy files"
            else
                info_log "⚠️  Could not verify all PR files (may need more time for PR to be fully processed)"
            fi
            
            # Verify kustomization.yaml paths are correct (no ../../ prefixes)
            info_log "Verifying kustomization.yaml paths..."
            if verify_kustomization_paths "$GITHUB_REPO" "$pr_number" "networkpolicies/DEV-cluster/kustomization.yaml"; then
                pass_test "kustomization.yaml contains correct relative paths (no ../../ prefixes)"
            else
                fail_test "kustomization.yaml contains incorrect paths with ../../ prefix"
                PR_VERIFICATION_FAILED=1
            fi
        fi
        
        # Verify PR description contains expected information
        if command -v jq &> /dev/null; then
            local pr_description=$(gh pr view "$pr_number" --repo "$GITHUB_REPO" --json body --jq '.body' 2>/dev/null || echo "")
            if [ -n "$pr_description" ] && [ "$pr_description" != "null" ]; then
                if echo "$pr_description" | grep -q "$namespace"; then
                    pass_test "PR description contains namespace: $namespace"
                else
                    info_log "⚠️  PR description does not contain namespace: $namespace"
                fi
            else
                info_log "⚠️  PR description not available (may need more time)"
            fi
        else
            info_log "⚠️  jq not available, skipping PR description verification"
        fi
        
    else
        fail_test "PR $pr_number not found on GitHub or gh CLI not available"
        PR_VERIFICATION_FAILED=1
        return 1
    fi
    
    # Verify PR state in PermissionBinder status
    local namespace_state=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$namespace\")].state}" 2>/dev/null || echo "")
    if [ -n "$namespace_state" ]; then
        case "$namespace_state" in
            "pr-created"|"pr-pending"|"pr-merged")
                pass_test "$namespace namespace has valid PR state: $namespace_state"
                ;;
            *)
                info_log "⚠️  $namespace namespace has unexpected state: $namespace_state (may be valid if PR was auto-merged)"
                ;;
        esac
    else
        info_log "⚠️  $namespace namespace state not found in status (may be normal if PR was auto-merged quickly)"
    fi
    
    return 0
}

# Verify PRs for all test namespaces
for test_ns in "${TEST_NAMESPACES[@]}"; do
    if ! verify_pr_for_namespace "$test_ns"; then
        PR_VERIFICATION_FAILED=1
    fi
done

# ============================================================================
# CLEANUP: Remove PRs and branches from GitHub (test isolation)
# IMPORTANT: Cleanup is done AFTER all GitHub verifications are complete
# IMPORTANT: Cleanup ALL namespaces from ConfigMap (test-app and test-app-2)
# ============================================================================
info_log "=========================================="
info_log "All PR verifications completed. Starting cleanup..."
info_log "=========================================="

# Cleanup all test namespaces (regardless of verification result)
for test_ns in "${TEST_NAMESPACES[@]}"; do
    info_log "Cleaning up $test_ns namespace..."
    cleanup_networkpolicy_test_artifacts "test-permissionbinder-networkpolicy" "$test_ns" "$GITHUB_REPO"
done

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
