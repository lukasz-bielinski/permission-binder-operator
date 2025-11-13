#!/bin/bash
# Test 59: NetworkPolicy - Namespace Removal Cleanup
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 59: NetworkPolicy - Namespace Removal Cleanup"
echo "--------------------------------------------------"

BINDER_NAME="test-permissionbinder-networkpolicy-removal"
CONFIGMAP_NAME="permission-config-removal"
GITHUB_REPO="lukasz-bielinski/tests-network-policies"
NAMESPACE_A="test-remove-a"
NAMESPACE_B="test-remove-b"

cleanup_resources() {
    cleanup_networkpolicy_test_artifacts "$BINDER_NAME" "$NAMESPACE_A" "$GITHUB_REPO" 2>/dev/null || true
    cleanup_networkpolicy_test_artifacts "$BINDER_NAME" "$NAMESPACE_B" "$GITHUB_REPO" 2>/dev/null || true
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
# 2. Create PermissionBinder with two namespaces
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

info_log "Creating initial ConfigMap with two namespaces"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIGMAP_NAME
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-$NAMESPACE_A-engineer,OU=Openshift,DC=example,DC=com
    CN=COMPANY-K8S-$NAMESPACE_B-engineer,OU=Openshift,DC=example,DC=com
EOF

info_log "Waiting for initial reconciliation (30s)"
sleep 30

# Wait for PR creation for NAMESPACE_A (primary)
PR_A=$(wait_for_pr_in_status "$BINDER_NAME" "$NAMESPACE_A" 180)
if [ -z "$PR_A" ]; then
    fail_test "PR not created for namespace $NAMESPACE_A"
    exit 1
fi
pass_test "Initial PR created for $NAMESPACE_A (PR: $PR_A)"

# Attempt to fetch PR for namespace B as well (optional)
PR_B=$(wait_for_pr_in_status "$BINDER_NAME" "$NAMESPACE_B" 60)
if [ -n "$PR_B" ]; then
    pass_test "Initial PR created for $NAMESPACE_B (PR: $PR_B)"
else
    info_log "⚠️  PR not yet visible for $NAMESPACE_B (may be skipped if already processed previously)"
fi

# ----------------------------------------------------------------------------
# 3. Remove namespace B and wait for cleanup
# ----------------------------------------------------------------------------
info_log "Updating ConfigMap to remove $NAMESPACE_B"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIGMAP_NAME
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-$NAMESPACE_A-engineer,OU=Openshift,DC=example,DC=com
EOF

info_log "Waiting for removal reconciliation (up to 180s)"
REMOVAL_STATE=""
for i in {1..36}; do
    REMOVAL_STATE=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.networkPolicies[?(@.namespace=="'$NAMESPACE_B'")].state}' 2>/dev/null || echo "")
    if [ "$REMOVAL_STATE" == "pr-removal" ] || [ "$REMOVAL_STATE" == "removed" ]; then
        break
    fi
    sleep 5
done

if [ "$REMOVAL_STATE" == "pr-removal" ] || [ "$REMOVAL_STATE" == "removed" ]; then
    pass_test "Namespace $NAMESPACE_B transitioned to removal state: $REMOVAL_STATE"
else
    fail_test "Namespace $NAMESPACE_B did not transition to removal state (current: ${REMOVAL_STATE:-none})"
fi

REMOVAL_PR=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.networkPolicies[?(@.namespace=="'$NAMESPACE_B'")].prNumber}' 2>/dev/null || echo "")
if [ -n "$REMOVAL_PR" ]; then
    pass_test "Removal PR recorded for $NAMESPACE_B (PR: $REMOVAL_PR)"
else
    info_log "⚠️  Removal PR number not recorded (may not have been created if namespace skipped)"
fi

REMOVED_AT=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.networkPolicies[?(@.namespace=="'$NAMESPACE_B'")].removedAt}' 2>/dev/null || echo "")
if [ -n "$REMOVED_AT" ]; then
    pass_test "RemovedAt timestamp populated: $REMOVED_AT"
else
    info_log "⚠️  RemovedAt not populated"
fi

# Verify remaining namespace still present
STATE_A=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.networkPolicies[?(@.namespace=="'$NAMESPACE_A'")].state}' 2>/dev/null || echo "")
if [ -n "$STATE_A" ]; then
    pass_test "Namespace $NAMESPACE_A still tracked (state: $STATE_A)"
else
    fail_test "$NAMESPACE_A status missing after removal"
fi

echo ""

# ============================================================================
