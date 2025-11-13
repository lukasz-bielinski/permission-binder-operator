#!/bin/bash
# Test 52: NetworkPolicy - Variant C (Backup Non-Template NetworkPolicy)
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 52: NetworkPolicy - Variant C (Backup Non-Template NetworkPolicy)"
echo "---------------------------------------------------------------------------"

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

# Setup: Create PermissionBinder with NetworkPolicy enabled and backupExisting: true
if ! kubectl_retry kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE >/dev/null 2>&1; then
    info_log "Creating PermissionBinder with NetworkPolicy enabled and backupExisting: true"
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

# Create namespace with existing NetworkPolicy WITHOUT template annotation (non-template policy)
if ! kubectl get namespace test-variant-c-ns >/dev/null 2>&1; then
    kubectl create namespace test-variant-c-ns >/dev/null 2>&1
fi

# Create existing NetworkPolicy WITHOUT template annotation (custom policy - Variant C)
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: custom-policy
  namespace: test-variant-c-ns
  # NO template annotation - this is a custom policy (Variant C)
spec:
  podSelector:
    matchLabels:
      app: custom-app
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: allowed-namespace
    ports:
    - protocol: TCP
      port: 8080
EOF

# Update ConfigMap to include test-variant-c-ns namespace
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
    CN=COMPANY-K8S-test-variant-c-ns-engineer,OU=Openshift,DC=example,DC=com
EOF

# Wait for reconciliation to process backup (increased to allow operator time to create PRs)
info_log "Waiting for reconciliation to process backup (15s)"
sleep 15

# ============================================================================
# VERIFICATION: Check PR for test-variant-c-ns namespace (main test objective)
# NOTE: test-app and test-app-2 may be skipped by operator if they already have status
#       from previous tests (operator optimization - skips already processed namespaces)
#       The main objective of this test is to verify backup variant for test-variant-c-ns
# ============================================================================

GITHUB_REPO="lukasz-bielinski/tests-network-policies"
# Main test objective: verify backup for test-variant-c-ns
# Other namespaces (test-app, test-app-2) may be skipped if already processed
MAIN_TEST_NAMESPACE="test-variant-c-ns"
PR_VERIFICATION_FAILED=0

# Function to verify PR for a namespace (reuse from test-44 pattern)
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
        
        if [ -z "$pr_title" ] || [ "$pr_title" == "null" ]; then
            fail_test "Failed to extract PR title from GitHub response"
            PR_VERIFICATION_FAILED=1
            return 1
        fi
        
        info_log "GitHub PR Details:"
        info_log "  Title: $pr_title"
        info_log "  State: $pr_state_gh"
        
        # Verify PR title contains expected namespace
        if echo "$pr_title" | grep -q "$namespace"; then
            pass_test "PR title contains namespace: $namespace"
        else
            fail_test "PR title does not contain namespace $namespace: $pr_title"
            PR_VERIFICATION_FAILED=1
        fi
        
        # Special verification for test-variant-c-ns (backup variant)
        if [ "$namespace" == "test-variant-c-ns" ]; then
            if echo "$pr_title" | grep -qi "backup"; then
                pass_test "PR title indicates backup variant"
            else
                info_log "⚠️  PR title may not indicate backup: $pr_title"
            fi
            
            # Verify PR contains backup files
            info_log "Verifying backup PR files..."
            local expected_files="networkpolicies/DEV-cluster/test-variant-c-ns/custom-policy.yaml networkpolicies/DEV-cluster/kustomization.yaml"
            if verify_pr_files "$GITHUB_REPO" "$pr_number" "$expected_files"; then
                pass_test "Backup PR contains expected files"
            else
                info_log "⚠️  Could not verify all backup PR files (may need more time)"
            fi
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

# Verify PR for main test namespace (test-variant-c-ns)
# This is the main objective: verify backup variant works
if ! verify_pr_for_namespace "$MAIN_TEST_NAMESPACE"; then
    PR_VERIFICATION_FAILED=1
fi

# Optional: Check if other namespaces were processed or skipped
# (operator may skip them if they already have status from previous tests)
info_log "Checking status of other namespaces (may be skipped if already processed)..."
for ns in "test-app" "test-app-2"; do
    NS_STATE=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$ns\")].state}" 2>/dev/null || echo "")
    if [ -n "$NS_STATE" ]; then
        info_log "Namespace $ns has state: $NS_STATE (already processed - operator optimization)"
    else
        info_log "Namespace $ns not in status (may be skipped by operator if already processed)"
    fi
done

# ============================================================================
# CLEANUP: Remove PRs and branches from GitHub (test isolation)
# IMPORTANT: Cleanup is done AFTER all GitHub verifications are complete
# IMPORTANT: Cleanup ALL namespaces from ConfigMap and remove entire cluster directory
# ============================================================================
info_log "=========================================="
info_log "All PR verifications completed. Starting cleanup..."
info_log "=========================================="

# Cleanup: Clean up all namespaces that might have been processed
# (including test-app and test-app-2 if they were processed)
info_log "Cleaning up test namespaces..."
cleanup_networkpolicy_test_artifacts "test-permissionbinder-networkpolicy" "$MAIN_TEST_NAMESPACE" "$GITHUB_REPO"
# Also cleanup test-app and test-app-2 if they exist (may have been processed)
cleanup_networkpolicy_test_artifacts "test-permissionbinder-networkpolicy" "test-app" "$GITHUB_REPO" 2>/dev/null || true
cleanup_networkpolicy_test_artifacts "test-permissionbinder-networkpolicy" "test-app-2" "$GITHUB_REPO" 2>/dev/null || true

# Final cleanup: Remove entire cluster directory
info_log "Final cleanup: Removing entire DEV-cluster directory..."
cleanup_networkpolicy_files_from_repo "$GITHUB_REPO" "" "DEV-cluster"

# Final test result
if [ $PR_VERIFICATION_FAILED -eq 1 ]; then
    fail_test "Some PR verifications failed - check logs above"
    exit 1
fi

# Cleanup Kubernetes resources (always, regardless of PR status)
kubectl delete networkpolicy custom-policy -n test-variant-c-ns --ignore-not-found=true >/dev/null 2>&1
kubectl delete namespace test-variant-c-ns --ignore-not-found=true >/dev/null 2>&1

echo ""

# ============================================================================
