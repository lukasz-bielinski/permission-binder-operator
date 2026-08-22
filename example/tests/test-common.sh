#!/bin/bash
# Common helper functions for E2E tests
# This file is sourced by individual test files and the main test runner
#
# Required environment variables (set by main script):
#   - NAMESPACE: Kubernetes namespace (default: permissions-binder-operator)
#   - TEST_RESULTS: Path to test results log file
#   - SCRIPT_DIR: Directory where test scripts are located

# Helper functions
pass_test() {
    echo "✅ PASS: $1" | tee -a ${TEST_RESULTS:-/tmp/e2e-test-results.log}
}

fail_test() {
    echo "❌ FAIL: $1" | tee -a ${TEST_RESULTS:-/tmp/e2e-test-results.log}
}

info_log() {
    echo "ℹ️  $1" | tee -a ${TEST_RESULTS:-/tmp/e2e-test-results.log}
}

# E2E_WAIT_MULT (default 1) multiplies harness-owned fixed sleeps/timeouts.
# The k3s API server on rpi4-class hardware is loaded when the suite runs in
# parallel (issue #36); the parallel runner exports a load-aware default.
# Tests should prefer e2e_sleep/e2e_max_wait over a bare `sleep N`/timeout so
# the multiplier is honored. Default: 1 (identical to current behavior).
E2E_WAIT_MULT="${E2E_WAIT_MULT:-1}"

# Sleep for $1 seconds scaled by E2E_WAIT_MULT.
e2e_sleep() {
    local seconds="$1"
    awk -v s="$seconds" -v m="$E2E_WAIT_MULT" 'BEGIN { d = s * m; if (d < 0) d = 0; cmd = "sleep " d; system(cmd) }'
}

# Scale a timeout/wait budget (seconds) by E2E_WAIT_MULT, rounded up, min 1.
e2e_max_wait() {
    local seconds="$1"
    awk -v s="$seconds" -v m="$E2E_WAIT_MULT" 'BEGIN { d = s * m; d = (d == int(d)) ? d : int(d) + 1; if (d < 1) d = 1; print d }'
}

# ---------------------------------------------------------------------------
# Instance-scoped helpers (issue #35)
#
# Under parallel instances, cluster-wide label queries and unfiltered metrics
# see SIBLING instances' resources. These helpers scope every read to the
# calling instance: label by MANAGED_BY_VALUE (unique per instance, see the
# runner) and ownership by the permission-binder + permission-binder-namespace
# annotations (namespace-aware since PR #38; legacy name-only resources match
# by name for backward compatibility).
# ---------------------------------------------------------------------------

MANAGED_BY_VALUE="${MANAGED_BY_VALUE:-permission-binder-operator}"
if [ -n "${INSTANCE:-}" ]; then
    MANAGED_BY_VALUE="permission-binder-operator-${INSTANCE}"
fi
MANAGED_BY_LABEL="permission-binder.io/managed-by=${MANAGED_BY_VALUE}"

# jq filter selecting resources owned by PermissionBinder $1 in $NAMESPACE.
# Matches new-style (name + namespace annotation) and legacy (name-only).
_OWNED_JQ='.items[] | select(
    .metadata.annotations["permission-binder.io/permission-binder"] == $pb and
    ((.metadata.annotations["permission-binder.io/permission-binder-namespace"] // $ns) == $ns))'

# count_owned_rolebindings <pb_name> - RoleBindings owned by this instance's CR
count_owned_rolebindings() {
    kubectl get rolebindings -A -l "$MANAGED_BY_LABEL" -o json 2>/dev/null \
        | jq --arg pb "$1" --arg ns "${NAMESPACE:?}" "[${_OWNED_JQ}] | length"
}

# list_owned_rolebindings <pb_name> - "namespace name" lines, own CR only
list_owned_rolebindings() {
    kubectl get rolebindings -A -l "$MANAGED_BY_LABEL" -o json 2>/dev/null \
        | jq -r --arg pb "$1" --arg ns "${NAMESPACE:?}" "${_OWNED_JQ} | .metadata.namespace + \" \" + .metadata.name"
}

# count_owned_namespaces <pb_name> - Namespaces owned by this instance's CR
count_owned_namespaces() {
    kubectl get namespaces -l "$MANAGED_BY_LABEL" -o json 2>/dev/null \
        | jq --arg pb "$1" --arg ns "${NAMESPACE:?}" "[${_OWNED_JQ}] | length"
}

# list_owned_namespaces <pb_name> - namespace names, own CR only
list_owned_namespaces() {
    kubectl get namespaces -l "$MANAGED_BY_LABEL" -o json 2>/dev/null \
        | jq -r --arg pb "$1" --arg ns "${NAMESPACE:?}" "${_OWNED_JQ} | .metadata.name"
}

# prom_query_raw <promql> - full JSON response from the shared Prometheus
# (same exec+wget transport the metrics tests use; no -c flag, kubectl picks
# the default container exactly like the tests always did).
prom_query_raw() {
    local prom_pod
    prom_pod=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [ -z "$prom_pod" ] && return 1
    kubectl exec -n monitoring "$prom_pod" -- \
        wget -q -O- "http://localhost:9090/api/v1/query?query=$(printf '%s' "$1" | jq -sRr @uri)" 2>/dev/null
}

# prom_query <promql> - value of the FIRST series or empty. Callers must
# already scope the expression with {namespace="$NAMESPACE"} (see prom_metric).
prom_query() {
    prom_query_raw "$1" | jq -r '.data.result[0].value[1] // empty'
}

# prom_metric <metric_name> - instance-scoped gauge/counter value: the metric
# filtered to THIS instance's operator namespace (empty if no sample yet).
prom_metric() {
    prom_query "${1}{namespace=\"${NAMESPACE:?}\"}"
}

# pick_free_port - free local TCP port for kubectl port-forward (avoids the
# fixed :8080 cross-instance collision)
pick_free_port() {
    python3 - <<'PYPORT' 2>/dev/null || echo $((20000 + RANDOM % 20000))
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PYPORT
}

# Retry kubectl commands with exponential backoff (for RPi k3s restarts)
kubectl_retry() {
    local max_attempts=5
    local timeout=2
    local attempt=1
    local exitCode=0
    
    while [ $attempt -le $max_attempts ]; do
        if "$@" 2>&1; then
            return 0
        else
            exitCode=$?
        fi
        
        # Check if it's a connection error
        if echo "$("$@" 2>&1)" | grep -qE "connection refused|ServiceUnavailable|i/o timeout"; then
            if [ $attempt -lt $max_attempts ]; then
                info_log "⚠️  K3s connection issue (attempt $attempt/$max_attempts), retrying in ${timeout}s..."
                sleep $timeout
                timeout=$((timeout * 2))  # Exponential backoff
                attempt=$((attempt + 1))
            else
                info_log "❌ K3s connection failed after $max_attempts attempts"
                return $exitCode
            fi
        else
            # Not a connection error, return immediately
            return $exitCode
        fi
    done
    
    return $exitCode
}

# ---------------------------------------------------------------------------
# ServiceAccount test fixtures (tests 31-41, issue #43 / PR #45)
#
# Under the first-owner-wins ownership gate, a PermissionBinder that references
# the SAME ConfigMap as the runner's baseline CR (permissionbinder-example) is
# refused ownership of the baseline-owned namespace/RoleBinding. Its entry
# never lands in processedRoleBindings, the ServiceAccount loop (which derives
# namespaces from processedRoleBindings) runs over zero namespaces, and the
# test passes or fails vacuously. Every SA test therefore provisions its OWN
# ConfigMap whose whitelist resolves to a DEDICATED namespace, making the CR
# under test the first (and only) owner of everything it manages.
# ---------------------------------------------------------------------------

# apply_yaml_with_retry - apply a manifest given on stdin. The manifest is
# staged to a temp file so kubectl_retry can safely re-run the command on
# connection errors (a piped stdin would be empty on the second attempt).
apply_yaml_with_retry() {
    local manifest rc
    manifest=$(mktemp)
    cat > "$manifest"
    kubectl_retry kubectl apply -f "$manifest" >/dev/null
    rc=$?
    rm -f "$manifest"
    return $rc
}

# create_sa_test_configmap <configmap_name> <managed_namespace> [more_ns...]
# ConfigMap in $NAMESPACE whose whitelist.txt CNs resolve to the given
# dedicated namespace(s) with the "developer" role (the PermissionBinder under
# test must map developer to some ClusterRole).
create_sa_test_configmap() {
    local cm_name=$1
    shift
    local whitelist="" ns
    for ns in "$@"; do
        whitelist="${whitelist}    CN=COMPANY-K8S-${ns}-developer,OU=Groups,DC=example,DC=com"$'\n'
    done
    whitelist=${whitelist%$'\n'}
    apply_yaml_with_retry <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${cm_name}
  namespace: ${NAMESPACE:?}
data:
  whitelist.txt: |
${whitelist}
EOF
}

# wait_for_cmd <timeout_s> <cmd...> - poll every 2s until cmd succeeds.
# Timeout is scaled by E2E_WAIT_MULT. Returns 1 on timeout.
wait_for_cmd() {
    local max waited=0
    max=$(e2e_max_wait "$1")
    shift
    while [ "$waited" -lt "$max" ]; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# wait_for_sa <namespace> <sa_name> [timeout_s=60] - poll until the
# ServiceAccount exists (also covers waiting for the namespace itself).
wait_for_sa() {
    wait_for_cmd "${3:-60}" kubectl get serviceaccount "$2" -n "$1"
}

# GitHub PR verification functions
# These functions use gh CLI to verify PRs created by the operator

# Wait for PR to appear in PermissionBinder status
# Returns PR number if found, empty string otherwise
wait_for_pr_in_status() {
    local namespace=$1
    local test_namespace=$2
    local max_wait=${3:-120}  # Default 120 seconds
    local waited=0
    local poll_interval=2  # Simple polling: check every 2 seconds
    
    while [ $waited -lt $max_wait ]; do
        # Check if PR number exists in status
        local pr_number=$(kubectl get permissionbinder "$namespace" -n "${NAMESPACE:?NAMESPACE must be set}" \
            -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$test_namespace\")].prNumber}" 2>/dev/null || echo "")
        
        # Also check PR state - if PR is already merged, we're done
        local pr_state=$(kubectl get permissionbinder "$namespace" -n "${NAMESPACE:?NAMESPACE must be set}" \
            -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$test_namespace\")].state}" 2>/dev/null || echo "")
        
        # If PR number exists, return it (PR created or merged)
        if [ -n "$pr_number" ] && [ "$pr_number" != "null" ] && [ "$pr_number" != "" ]; then
            echo "$pr_number"
            return 0
        fi
        
        # If PR state is pr-merged, we can also return (PR was merged before status update)
        if [ "$pr_state" == "pr-merged" ]; then
            # Try to get PR number one more time
            pr_number=$(kubectl get permissionbinder "$namespace" -n "${NAMESPACE:?NAMESPACE must be set}" \
                -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$test_namespace\")].prNumber}" 2>/dev/null || echo "")
            if [ -n "$pr_number" ] && [ "$pr_number" != "null" ] && [ "$pr_number" != "" ]; then
                echo "$pr_number"
                return 0
            fi
        fi
        
        sleep $poll_interval
        waited=$((waited + poll_interval))
    done
    
    return 1
}

# Get PR details from PermissionBinder status
get_pr_from_status() {
    local namespace=$1
    local test_namespace=$2
    
    local pr_number=$(kubectl get permissionbinder "$namespace" -n "${NAMESPACE:?NAMESPACE must be set}" \
        -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$test_namespace\")].prNumber}" 2>/dev/null || echo "")
    local pr_url=$(kubectl get permissionbinder "$namespace" -n "${NAMESPACE:?NAMESPACE must be set}" \
        -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$test_namespace\")].prUrl}" 2>/dev/null || echo "")
    local pr_branch=$(kubectl get permissionbinder "$namespace" -n "${NAMESPACE:?NAMESPACE must be set}" \
        -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$test_namespace\")].prBranch}" 2>/dev/null || echo "")
    local pr_state=$(kubectl get permissionbinder "$namespace" -n "${NAMESPACE:?NAMESPACE must be set}" \
        -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$test_namespace\")].state}" 2>/dev/null || echo "")
    
    echo "$pr_number|$pr_url|$pr_branch|$pr_state"
}

# Verify PR exists on GitHub using gh CLI
verify_pr_on_github() {
    local repo=$1  # e.g., "lukasz-bielinski/tests-network-policies"
    local pr_number=$2
    
    if [ -z "$pr_number" ] || [ "$pr_number" == "null" ] || [ "$pr_number" == "" ]; then
        return 1
    fi
    
    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        info_log "⚠️  gh CLI not available, skipping GitHub PR verification"
        return 1
    fi
    
    # Check if gh is authenticated
    if ! gh auth status &>/dev/null; then
        info_log "⚠️  gh CLI not authenticated, skipping GitHub PR verification"
        return 1
    fi
    
    # Check if jq is available (needed for JSON parsing)
    # jq is verified at test start, but double-check here
    if ! command -v jq &> /dev/null; then
        fail_test "CRITICAL: jq is required for GitHub PR verification but not found. Install: sudo apt-get install jq"
        return 1
    fi
    
    # Get PR details
    local pr_json=$(gh pr view "$pr_number" --repo "$repo" --json number,state,title,headRefName,url,labels 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$pr_json" ]; then
        echo "$pr_json"
        return 0
    fi
    
    return 1
}

# Verify PR contains expected files
verify_pr_files() {
    local repo=$1  # e.g., "lukasz-bielinski/tests-network-policies"
    local pr_number=$2
    local expected_files=$3  # Space-separated list of file paths
    
    if [ -z "$pr_number" ] || [ "$pr_number" == "null" ] || [ "$pr_number" == "" ]; then
        return 1
    fi
    
    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        info_log "⚠️  gh CLI not available, skipping PR file verification"
        return 1
    fi
    
    # Check if jq is available
    # jq is verified at test start, but double-check here
    if ! command -v jq &> /dev/null; then
        fail_test "CRITICAL: jq is required for PR file verification but not found. Install: sudo apt-get install jq"
        return 1
    fi
    
    # Get PR files
    local pr_files=$(gh pr view "$pr_number" --repo "$repo" --json files --jq '.files[].path' 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$pr_files" ]; then
        return 1
    fi
    
    # Check each expected file
    local missing_files=""
    for expected_file in $expected_files; do
        if ! echo "$pr_files" | grep -q "^${expected_file}$"; then
            missing_files="${missing_files} ${expected_file}"
        fi
    done
    
    if [ -n "$missing_files" ]; then
        info_log "⚠️  PR $pr_number missing files:$missing_files"
        return 1
    fi
    
    return 0
}

# Verify PR file content
verify_pr_file_content() {
    local repo=$1  # e.g., "lukasz-bielinski/tests-network-policies"
    local pr_number=$2
    local file_path=$3
    local expected_content_pattern=$4  # Regex pattern to match
    
    if [ -z "$pr_number" ] || [ "$pr_number" == "null" ] || [ "$pr_number" == "" ]; then
        return 1
    fi
    
    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        info_log "⚠️  gh CLI not available, skipping PR file content verification"
        return 1
    fi
    
    # Check if jq is available
    # jq is verified at test start, but double-check here
    if ! command -v jq &> /dev/null; then
        fail_test "CRITICAL: jq is required for PR file content verification but not found. Install: sudo apt-get install jq"
        return 1
    fi
    
    # Get file content from PR
    local file_content=$(gh pr view "$pr_number" --repo "$repo" --json files --jq ".files[] | select(.path==\"$file_path\") | .additions" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$file_content" ]; then
        return 1
    fi
    
    # For now, just check if file exists in PR
    # Full content verification would require fetching the actual file content
    # which is more complex with gh CLI
    return 0
}

# Verify kustomization.yaml contains correct paths (no ../../ prefixes)
verify_kustomization_paths() {
    local repo=$1  # e.g., "lukasz-bielinski/tests-network-policies"
    local pr_number=$2
    local kustomization_path=$3  # e.g., "networkpolicies/DEV-cluster/kustomization.yaml"
    
    if [ -z "$pr_number" ] || [ "$pr_number" == "null" ] || [ "$pr_number" == "" ]; then
        return 1
    fi
    
    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        info_log "⚠️  gh CLI not available, skipping kustomization verification"
        return 1
    fi
    
    # Check if jq is available (for JSON parsing if needed)
    # jq is verified at test start, but double-check here
    if ! command -v jq &> /dev/null; then
        fail_test "CRITICAL: jq is required for kustomization verification but not found. Install: sudo apt-get install jq"
        return 1
    fi
    
    # Get PR diff for kustomization.yaml
    local diff_output=$(gh pr diff "$pr_number" --repo "$repo" "$kustomization_path" 2>/dev/null)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Check for incorrect paths (../../ prefixes)
    if echo "$diff_output" | grep -qE "^\+\s*\.\./\.\./"; then
        info_log "⚠️  PR $pr_number kustomization.yaml contains incorrect paths with ../../ prefix"
        return 1
    fi
    
    return 0
}

# Wait for PR state to change (e.g., pr-pending -> pr-merged)
wait_for_pr_state() {
    local namespace=$1
    local test_namespace=$2
    local expected_state=$3
    local max_wait=${4:-60}  # Default 60 seconds
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        local current_state=$(kubectl get permissionbinder "$namespace" -n "${NAMESPACE:?NAMESPACE must be set}" \
            -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$test_namespace\")].state}" 2>/dev/null || echo "")
        
        if [ "$current_state" == "$expected_state" ]; then
            return 0
        fi
        
        sleep 5
        waited=$((waited + 5))
    done
    
    return 1
}

# Cleanup PR and branch from GitHub (for test isolation)
# This ensures tests are fully self-contained and clean up after themselves
cleanup_pr_and_branch() {
    local repo=$1  # e.g., "lukasz-bielinski/tests-network-policies"
    local pr_number=$2
    local branch_name=$3
    
    if [ -z "$repo" ] || [ -z "$pr_number" ] || [ "$pr_number" == "null" ] || [ "$pr_number" == "" ]; then
        info_log "⚠️  Skipping cleanup: missing repo or PR number"
        return 0
    fi
    
    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        info_log "⚠️  gh CLI not available, skipping PR/branch cleanup"
        return 0
    fi
    
    info_log "Cleaning up PR $pr_number and branch $branch_name from GitHub..."
    
    # Close PR if it's still open
    local pr_state=$(gh pr view "$pr_number" --repo "$repo" --json state --jq '.state' 2>/dev/null || echo "")
    if [ "$pr_state" == "OPEN" ]; then
        info_log "Closing PR $pr_number..."
        gh pr close "$pr_number" --repo "$repo" --delete-branch=false 2>/dev/null || true
    fi
    
    # Delete branch if it exists
    if [ -n "$branch_name" ] && [ "$branch_name" != "" ]; then
        info_log "Deleting branch $branch_name..."
        gh api repos/"$repo"/git/refs/heads/"$branch_name" -X DELETE 2>/dev/null || true
    fi
    
    info_log "✅ Cleanup completed for PR $pr_number"
}

# Delete file from GitHub repository using GitHub API
# Usage: delete_file_from_github <repo> <file_path> <commit_message>
delete_file_from_github() {
    local repo=$1
    local file_path=$2
    local commit_message=$3
    
    if [ -z "$repo" ] || [ -z "$file_path" ] || [ -z "$commit_message" ]; then
        return 1
    fi
    
    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        return 1
    fi
    
    # Get file SHA (required for deletion)
    local file_sha=$(gh api repos/"$repo"/contents/"$file_path" --jq '.sha' 2>/dev/null || echo "")
    if [ -z "$file_sha" ] || [ "$file_sha" == "null" ]; then
        # File doesn't exist, nothing to delete
        return 0
    fi
    
    # Delete file using GitHub API
    gh api repos/"$repo"/contents/"$file_path" \
        -X DELETE \
        -f message="$commit_message" \
        -f sha="$file_sha" \
        >/dev/null 2>&1
    
    return $?
}

# Cleanup NetworkPolicy files from GitHub repository
# Simplified: Removes entire cluster_name directory and all its content (files and subdirectories)
# Usage: cleanup_networkpolicy_files_from_repo <github_repo> <test_namespace> <cluster_name>
cleanup_networkpolicy_files_from_repo() {
    local github_repo=$1  # e.g., "lukasz-bielinski/tests-network-policies"
    local test_namespace=$2  # e.g., "test-app" (not used, kept for compatibility)
    local cluster_name=${3:-"DEV-cluster"}  # Default to DEV-cluster
    
    if [ -z "$github_repo" ] || [ -z "$cluster_name" ]; then
        info_log "⚠️  Skipping file cleanup: missing required parameters"
        return 0
    fi
    
    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        info_log "⚠️  gh CLI not available, skipping file cleanup"
        return 0
    fi
    
    info_log "Cleaning up entire $cluster_name directory and all its content from repository (self-contained test isolation)..."
    
    local cluster_dir="networkpolicies/${cluster_name}"
    
    # Recursive function to delete all files in a directory tree
    # Returns: number of deleted files (via stdout, logs go to stderr)
    delete_directory_tree() {
        local dir_path=$1
        local deleted_count=0
        
        # List all items in directory (files and subdirectories)
        local items=$(gh api repos/"$github_repo"/contents/"$dir_path" --jq '.[].name' 2>/dev/null || echo "")
        
        if [ -z "$items" ] || [ "$items" == "" ]; then
            echo 0
            return 0
        fi
        
        # Process each item
        for item in $items; do
            local item_path="${dir_path}/${item}"
            
            # Check if it's a file or directory
            # For directories, API returns array; for files, it returns object with 'type' field
            local item_info=$(gh api repos/"$github_repo"/contents/"$item_path" 2>/dev/null || echo "")
            local item_json_type=$(echo "$item_info" | jq -r 'if type=="array" then "dir" else .type end' 2>/dev/null || echo "")
            
            if [ "$item_json_type" == "file" ]; then
                # Delete file (redirect logs to stderr)
                if delete_file_from_github "$github_repo" "$item_path" "Cleanup: Remove test NetworkPolicy file" 2>/dev/null; then
                    info_log "Deleted file: $item_path" >&2
                    deleted_count=$((deleted_count + 1))
                else
                    info_log "⚠️  Failed to delete file: $item_path" >&2
                fi
            elif [ "$item_json_type" == "dir" ]; then
                # Recursively delete subdirectory content first (directories are auto-deleted when empty)
                local subdir_count=$(delete_directory_tree "$item_path" 2>/dev/null)
                deleted_count=$((deleted_count + ${subdir_count:-0}))
            fi
            # Note: We don't delete directories directly - GitHub API doesn't support it
            # Directories are automatically removed when all files are deleted
        done
        
        echo $deleted_count
    }
    
    # Delete entire cluster directory tree
    # Capture stdout (number) separately from stderr (logs)
    local cleanup_output=$(delete_directory_tree "$cluster_dir" 2>&1)
    # Extract the number from the last line (function returns count via echo)
    local total_deleted=$(echo "$cleanup_output" | awk '/^[0-9]+$/ {last=$0} END {print last+0}')
    
    # Ensure total_deleted is a number
    if ! [[ "$total_deleted" =~ ^[0-9]+$ ]]; then
        total_deleted=0
    fi
    
    if [ "${total_deleted:-0}" -gt 0 ]; then
        info_log "✅ Cleaned up $total_deleted file(s) from $cluster_name directory"
    else
        info_log "⚠️  No files were deleted from $cluster_name directory (directory not found or empty)"
    fi
}

# Cleanup NetworkPolicy test artifacts from GitHub (common function for all NetworkPolicy tests)
# This function:
# 1. Gets PR number from PermissionBinder status
# 2. Gets branch name from PR details or GitHub API
# 3. Checks if PR was merged
# 4. If merged, deletes files from main branch
# 5. Closes PR and deletes branch
# 
# Usage: cleanup_networkpolicy_test_artifacts <permissionbinder_name> <test_namespace> <github_repo> [cluster_name]
# Example: cleanup_networkpolicy_test_artifacts "test-permissionbinder-networkpolicy" "test-app" "lukasz-bielinski/tests-network-policies" "DEV-cluster"
cleanup_networkpolicy_test_artifacts() {
    local permissionbinder_name=$1  # e.g., "test-permissionbinder-networkpolicy"
    local test_namespace=$2         # e.g., "test-app"
    local github_repo=$3            # e.g., "lukasz-bielinski/tests-network-policies"
    local cluster_name=${4:-"DEV-cluster"}  # Default to DEV-cluster
    
    if [ -z "$permissionbinder_name" ] || [ -z "$test_namespace" ] || [ -z "$github_repo" ]; then
        info_log "⚠️  Skipping cleanup: missing required parameters"
        return 0
    fi
    
    info_log "Cleaning up NetworkPolicy test artifacts for namespace $test_namespace..."
    
    # ALWAYS cleanup files from repo (self-contained test isolation)
    # Even if PR number is not in status, files might exist in repo from merged PRs
    info_log "Cleaning up NetworkPolicy files from repository (self-contained test isolation)..."
    cleanup_networkpolicy_files_from_repo "$github_repo" "$test_namespace" "$cluster_name"
    
    # Get PR number from PermissionBinder status (for PR/branch cleanup)
    local pr_number=$(kubectl get permissionbinder "$permissionbinder_name" -n "${NAMESPACE:?NAMESPACE must be set}" \
        -o jsonpath="{.status.networkPolicies[?(@.namespace==\"$test_namespace\")].prNumber}" 2>/dev/null || echo "")
    
    # If PR number not in status, try to find it from GitHub by branch name
    if [ -z "$pr_number" ] || [ "$pr_number" == "null" ] || [ "$pr_number" == "" ]; then
        info_log "⚠️  No PR number found in status, trying to find PR from GitHub..."
        if command -v gh &> /dev/null && command -v jq &> /dev/null; then
            local branch_name="networkpolicy/${cluster_name}/${test_namespace}"
            pr_number=$(gh pr list --repo "$github_repo" --head "$branch_name" --state all --json number --limit 1 --jq '.[0].number' 2>/dev/null || echo "")
            if [ -n "$pr_number" ] && [ "$pr_number" != "null" ] && [ "$pr_number" != "" ]; then
                info_log "Found PR number from GitHub: $pr_number"
            fi
        fi
    fi
    
    # Get PR details from status
    local pr_details=$(get_pr_from_status "$permissionbinder_name" "$test_namespace")
    local pr_branch=""
    local pr_state=""
    
    if [ -n "$pr_details" ]; then
        IFS='|' read -r pr_num pr_url pr_branch pr_state <<< "$pr_details"
    fi
    
    # If branch name or state not found in status, try to get it from GitHub API
    if [ -z "$pr_branch" ] || [ "$pr_branch" == "" ] || [ -z "$pr_state" ] || [ "$pr_state" == "" ]; then
        if command -v gh &> /dev/null && command -v jq &> /dev/null; then
            if [ -z "$pr_branch" ] || [ "$pr_branch" == "" ]; then
                pr_branch=$(gh pr view "$pr_number" --repo "$github_repo" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
            fi
            if [ -z "$pr_state" ] || [ "$pr_state" == "" ]; then
                pr_state=$(gh pr view "$pr_number" --repo "$github_repo" --json state --jq '.state' 2>/dev/null || echo "")
            fi
        fi
    fi
    
    # Cleanup PR and branch (if PR number was found)
    if [ -n "$pr_number" ] && [ "$pr_number" != "null" ] && [ "$pr_number" != "" ]; then
        # Ignore 422 errors (branch already deleted) - redirect stderr and filter
        cleanup_pr_and_branch "$github_repo" "$pr_number" "$pr_branch" 2>&1 | grep -v "Reference does not exist" || true
    else
        info_log "⚠️  No PR number found, skipping PR/branch cleanup"
    fi
}

# Cleanup all NetworkPolicy test artifacts from GitHub (for tests that don't create PRs but may check existing ones)
# This function cleans up all PRs found in PermissionBinder status for test namespaces
# At the end, removes entire cluster_name directory (self-contained test isolation)
# Usage: cleanup_all_networkpolicy_test_artifacts <permissionbinder_name> <github_repo> [cluster_name]
# Example: cleanup_all_networkpolicy_test_artifacts "test-permissionbinder-networkpolicy" "lukasz-bielinski/tests-network-policies" "DEV-cluster"
cleanup_all_networkpolicy_test_artifacts() {
    local permissionbinder_name=$1  # e.g., "test-permissionbinder-networkpolicy"
    local github_repo=$2            # e.g., "lukasz-bielinski/tests-network-policies"
    local cluster_name=${3:-"DEV-cluster"}  # Default to DEV-cluster
    
    if [ -z "$permissionbinder_name" ] || [ -z "$github_repo" ]; then
        info_log "⚠️  Skipping cleanup: missing required parameters"
        return 0
    fi
    
    info_log "Cleaning up all NetworkPolicy test artifacts from GitHub..."
    
    # Get all namespaces with PRs from PermissionBinder status
    local namespaces=$(kubectl get permissionbinder "$permissionbinder_name" -n "${NAMESPACE:?NAMESPACE must be set}" \
        -o jsonpath='{.status.networkPolicies[*].namespace}' 2>/dev/null || echo "")
    
    if [ -z "$namespaces" ] || [ "$namespaces" == "" ]; then
        info_log "⚠️  No NetworkPolicy namespaces found in status, skipping namespace cleanup"
    else
        # Cleanup PRs for each namespace
        for ns in $namespaces; do
            cleanup_networkpolicy_test_artifacts "$permissionbinder_name" "$ns" "$github_repo" "$cluster_name"
        done
    fi
    
    # Final cleanup: Remove entire cluster_name directory (self-contained test isolation)
    # This ensures complete cleanup even if some PRs were merged or files exist in main branch
    info_log "=========================================="
    info_log "Final cleanup: Removing entire $cluster_name directory..."
    info_log "=========================================="
    cleanup_networkpolicy_files_from_repo "$github_repo" "" "$cluster_name"  # Empty namespace = cleanup entire cluster dir
}
