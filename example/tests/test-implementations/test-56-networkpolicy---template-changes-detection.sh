#!/bin/bash
# Test 56: NetworkPolicy - Template Changes Detection
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 56: NetworkPolicy - Template Changes Detection"
echo "----------------------------------------------------"

if ! command -v gh &> /dev/null; then
    fail_test "gh CLI is required for template modification"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    fail_test "jq is required for parsing GitHub API responses"
    exit 1
fi

BINDER_NAME="test-permissionbinder-networkpolicy-template"
CONFIGMAP_NAME="permission-config-template"
TEST_NAMESPACE="test-template-changes"
GITHUB_REPO="lukasz-bielinski/tests-network-policies"
TEMPLATE_PATH="networkpolicies/templates/deny-all-ingress.yaml"
METRICS_PORT=8080

ORIGINAL_TEMPLATE_BASE64=""
UPDATED_TEMPLATE_SHA=""

cleanup_resources() {
    if [ -n "$UPDATED_TEMPLATE_SHA" ] && [ -n "$ORIGINAL_TEMPLATE_BASE64" ]; then
        info_log "Reverting template file to original content"
        gh api repos/"$GITHUB_REPO"/contents/"$TEMPLATE_PATH" \
            -X PUT \
            -f message="Test 56: revert template update" \
            -f sha="$UPDATED_TEMPLATE_SHA" \
            -f content="$ORIGINAL_TEMPLATE_BASE64" >/dev/null 2>&1 || info_log "⚠️  Failed to revert template automatically"
    fi

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
# 2. Create PermissionBinder with short reconciliation interval
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

info_log "Waiting for initial reconciliation and PR creation (20s)"
sleep 20

INITIAL_PR=$(wait_for_pr_in_status "$BINDER_NAME" "$TEST_NAMESPACE" 180)
if [ -z "$INITIAL_PR" ]; then
    fail_test "Initial PR not found for namespace $TEST_NAMESPACE"
    exit 1
fi
pass_test "Initial PR created (number: $INITIAL_PR)"

# Merge initial PR to simulate steady state
if ! gh pr merge "$INITIAL_PR" --repo "$GITHUB_REPO" --merge --admin >/dev/null 2>&1; then
    info_log "⚠️  Failed to merge initial PR automatically (may already be merged or checks failing)"
fi

info_log "Waiting for operator to record pr-merged (30s)"
wait_for_pr_state "$BINDER_NAME" "$TEST_NAMESPACE" "pr-merged" 120 >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
# 4. Modify template file to trigger template change detection
# ----------------------------------------------------------------------------
info_log "Fetching current template content"
TEMPLATE_JSON=$(gh api repos/"$GITHUB_REPO"/contents/"$TEMPLATE_PATH" 2>/dev/null)
if [ -z "$TEMPLATE_JSON" ]; then
    fail_test "Failed to fetch template content from GitHub"
    exit 1
fi

ORIGINAL_TEMPLATE_BASE64=$(echo "$TEMPLATE_JSON" | jq -r '.content' | tr -d '\n')
ORIGINAL_TEMPLATE_SHA=$(echo "$TEMPLATE_JSON" | jq -r '.sha')

TMP_TEMPLATE=$(mktemp)
echo "$ORIGINAL_TEMPLATE_BASE64" | base64 -d > "$TMP_TEMPLATE"

# Append comment to indicate change
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "# Test 56 template update at $TIMESTAMP" >> "$TMP_TEMPLATE"

UPDATED_TEMPLATE_BASE64=$(base64 < "$TMP_TEMPLATE" | tr -d '\n')
info_log "Updating template in GitHub to simulate change"
UPDATE_RESPONSE=$(gh api repos/"$GITHUB_REPO"/contents/"$TEMPLATE_PATH" \
    -X PUT \
    -f message="Test 56: template update" \
    -f sha="$ORIGINAL_TEMPLATE_SHA" \
    -f content="$UPDATED_TEMPLATE_BASE64" 2>/dev/null)

if [ -z "$UPDATE_RESPONSE" ]; then
    fail_test "Failed to update template file"
    exit 1
fi

UPDATED_TEMPLATE_SHA=$(echo "$UPDATE_RESPONSE" | jq -r '.content.sha')
info_log "Template updated, waiting for periodic reconciliation (30s)"
sleep 30

# ----------------------------------------------------------------------------
# 5. Verify new PR created due to template change
# ----------------------------------------------------------------------------
NEW_PR=""
MAX_WAIT=180
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    NEW_PR=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.networkPolicies[?(@.namespace=="'$TEST_NAMESPACE'")].prNumber}' 2>/dev/null || echo "")
    if [ -n "$NEW_PR" ] && [ "$NEW_PR" != "$INITIAL_PR" ]; then
        break
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

if [ -n "$NEW_PR" ] && [ "$NEW_PR" != "$INITIAL_PR" ]; then
    pass_test "New PR created after template change (number: $NEW_PR)"
else
    fail_test "Failed to detect new PR after template change (initial PR: $INITIAL_PR, current: ${NEW_PR:-none})"
fi

# ----------------------------------------------------------------------------
# 6. Capture updated reconciliation timestamp
# ----------------------------------------------------------------------------
LAST_RECONCILIATION=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.lastNetworkPolicyReconciliation}' 2>/dev/null || echo "")
if [ -n "$LAST_RECONCILIATION" ]; then
    pass_test "LastNetworkPolicyReconciliation updated: $LAST_RECONCILIATION"
else
    info_log "⚠️  lastNetworkPolicyReconciliation not found"
fi

# Cleanup handled by trap (revert template, cleanup PR artifacts)
echo ""

# ============================================================================
