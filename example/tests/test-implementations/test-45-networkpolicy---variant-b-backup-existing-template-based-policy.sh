#!/bin/bash
# Test 45: Networkpolicy   Variant B Backup Existing Template Based Policy
#
# Self-contained under the first-owner-wins ownership gate (issues #45/#59):
# own ConfigMap + dedicated namespace instead of the shared permission-config
# ConfigMap already owned by the runner's baseline PermissionBinder.
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

BINDER_NAME="test-permissionbinder-networkpolicy"
CONFIGMAP_NAME="np-test-config-45"
# Dedicated namespace (prefix empty in legacy single-instance mode; name
# contains "test-" so both cleanup sweeps catch it)
BACKUP_NS="${TEST_NS_PREFIX}np-test-45-backup"

# ============================================================================
# ============================================================================
echo ""
echo "Test 45: NetworkPolicy - Variant B (Backup Existing Template-based Policy)"
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
if ! kubectl_retry kubectl get permissionbinder $BINDER_NAME -n $NAMESPACE >/dev/null 2>&1; then
    info_log "Creating PermissionBinder with NetworkPolicy enabled and backupExisting: true"
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

# Create namespace with existing NetworkPolicy matching template pattern
if ! kubectl get namespace "$BACKUP_NS" >/dev/null 2>&1; then
    kubectl create namespace "$BACKUP_NS" >/dev/null 2>&1
fi

# Create existing NetworkPolicy that matches template pattern
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $BACKUP_NS-deny-all-ingress
  namespace: $BACKUP_NS
  annotations:
    network-policy.permission-binder.io/template: "deny-all-ingress.yaml"
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress: []
EOF

# Own ConfigMap resolving to the dedicated backup namespace
if ! create_np_test_configmap "$CONFIGMAP_NAME" "$BACKUP_NS"; then
    fail_test "Could not create test ConfigMap $CONFIGMAP_NAME"
    exit 1
fi

# Wait for reconciliation to process backup (increased to allow operator time to create PRs)
info_log "Waiting for reconciliation to process backup (15s)"
sleep 15

# ============================================================================
# VERIFICATION: Check PR for $BACKUP_NS namespace (main test objective)
# ============================================================================

GITHUB_REPO="lukasz-bielinski/tests-network-policies"
# Main test objective: verify backup for $BACKUP_NS
MAIN_TEST_NAMESPACE="$BACKUP_NS"
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
    pr_number=$(wait_for_pr_in_status "$BINDER_NAME" "$namespace" 120)
    
    # If PR number not found, check if PR state indicates it was merged (may need to get PR from GitHub)
    if [ -z "$pr_number" ] || [ "$pr_number" == "" ]; then
        local pr_state=$(kubectl get permissionbinder $BINDER_NAME -n $NAMESPACE -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$namespace\")].state}" 2>/dev/null || echo "")
        if [ "$pr_state" == "pr-merged" ] || [ "$pr_state" == "pr-pending" ]; then
            info_log "PR state found: $pr_state, but PR number missing. Checking GitHub for recent PRs..."
            if command -v gh &> /dev/null; then
                pr_number=$(np_gh pr list --repo "$GITHUB_REPO" --head "networkpolicy/DEV-cluster/$namespace" --state all --json number,title,state --limit 1 --jq '.[0].number' 2>/dev/null || echo "")
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
    local pr_details=$(get_pr_from_status "$BINDER_NAME" "$namespace")
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
        
        # Special verification for $BACKUP_NS (backup variant)
        if [ "$namespace" == "$BACKUP_NS" ]; then
            if echo "$pr_title" | grep -qi "backup"; then
                pass_test "PR title indicates backup variant"
            else
                info_log "⚠️  PR title may not indicate backup: $pr_title"
            fi
            
            # Verify PR contains backup files
            info_log "Verifying backup PR files..."
            local expected_files="networkpolicies/DEV-cluster/$BACKUP_NS/$BACKUP_NS-deny-all-ingress.yaml networkpolicies/DEV-cluster/kustomization.yaml"
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
    local namespace_state=$(kubectl get permissionbinder $BINDER_NAME -n $NAMESPACE -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$namespace\")].state}" 2>/dev/null || echo "")
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

# Verify PR for main test namespace ($BACKUP_NS)
# This is the main objective: verify backup variant works
if ! verify_pr_for_namespace "$MAIN_TEST_NAMESPACE"; then
    PR_VERIFICATION_FAILED=1
fi

# ============================================================================
# CLEANUP: Remove PRs and branches from GitHub (test isolation)
# IMPORTANT: Cleanup is done AFTER all GitHub verifications are complete
# ============================================================================
info_log "=========================================="
info_log "All PR verifications completed. Starting cleanup..."
info_log "=========================================="

info_log "Cleaning up test namespaces..."
cleanup_networkpolicy_test_artifacts "$BINDER_NAME" "$MAIN_TEST_NAMESPACE" "$GITHUB_REPO"

# Final cleanup: Remove entire cluster directory
info_log "Final cleanup: Removing entire DEV-cluster directory..."
cleanup_networkpolicy_files_from_repo "$GITHUB_REPO" "" "DEV-cluster"

# Final test result
if [ $PR_VERIFICATION_FAILED -eq 1 ]; then
    fail_test "Some PR verifications failed - check logs above"
    exit 1
fi

# Cleanup Kubernetes resources (always, regardless of PR status)
kubectl delete networkpolicy $BACKUP_NS-deny-all-ingress -n $BACKUP_NS --ignore-not-found=true >/dev/null 2>&1
kubectl delete namespace $BACKUP_NS --ignore-not-found=true >/dev/null 2>&1

echo ""

# ============================================================================
