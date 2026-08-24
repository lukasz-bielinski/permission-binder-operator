#!/bin/bash
# Test 47: Networkpolicy   Exclude Lists
#
# Self-contained under the first-owner-wins ownership gate (issues #45/#59):
# provisions its OWN PermissionBinder + ConfigMap instead of mutating the
# shared permission-config ConfigMap (owned by the runner's baseline CR, which
# would create unprefixed orphan namespaces) and reading a PermissionBinder
# that does not exist under full isolation.
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

BINDER_NAME="test-permissionbinder-networkpolicy-exclude"
CONFIGMAP_NAME="np-test-config-47"
# Dedicated namespace (prefix empty in legacy single-instance mode; name
# contains "test-" so both cleanup sweeps catch it)
TEST_NAMESPACE="${TEST_NS_PREFIX}np-test-47"
GITHUB_REPO="lukasz-bielinski/tests-network-policies"

# ============================================================================
# ============================================================================
echo ""
echo "Test 47: NetworkPolicy - Exclude Lists"
echo "---------------------------------------"

cleanup_resources() {
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
# 2. Create PermissionBinder with kube-system in the NP exclude list
# ----------------------------------------------------------------------------
info_log "Creating PermissionBinder $BINDER_NAME with excludeNamespaces"
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

# Own ConfigMap: one dedicated namespace + an excluded one (kube-system)
if ! create_np_test_configmap "$CONFIGMAP_NAME" "$TEST_NAMESPACE" "kube-system"; then
    fail_test "Could not create test ConfigMap $CONFIGMAP_NAME"
    exit 1
fi

# Wait for reconciliation
info_log "Waiting for reconciliation (10s)"
sleep 10

# ----------------------------------------------------------------------------
# 3. Verify the non-excluded namespace IS processed and kube-system is NOT
# ----------------------------------------------------------------------------
MAX_WAIT=60
WAITED=0
ALL_NAMESPACES=""
while [ $WAITED -lt $MAX_WAIT ]; do
    ALL_NAMESPACES=$(kubectl get permissionbinder "$BINDER_NAME" -n $NAMESPACE -o jsonpath='{.status.networkPolicies[*].namespace}' 2>/dev/null || echo "")
    if [ -n "$ALL_NAMESPACES" ]; then
        break
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

INCLUDED_FOUND=false
EXCLUDED_FOUND=false
for ns in $ALL_NAMESPACES; do
    if [ "$ns" == "$TEST_NAMESPACE" ]; then
        INCLUDED_FOUND=true
    fi
    if [ "$ns" == "kube-system" ]; then
        EXCLUDED_FOUND=true
    fi
done

if [ "$INCLUDED_FOUND" == "true" ]; then
    pass_test "Non-excluded namespace $TEST_NAMESPACE is processed for NetworkPolicy"
else
    fail_test "Non-excluded namespace $TEST_NAMESPACE not found in NetworkPolicy status after ${MAX_WAIT}s"
fi

if [ "$EXCLUDED_FOUND" == "false" ]; then
    pass_test "kube-system is correctly excluded from NetworkPolicy processing"
else
    fail_test "kube-system should be excluded but was found in NetworkPolicy status"
fi

# Wait for the PR to be recorded before finishing so the EXIT-trap cleanup
# can find and remove it (avoids leaking an in-flight PR/branch).
PR_NUMBER=$(wait_for_pr_in_status "$BINDER_NAME" "$TEST_NAMESPACE" 120)
if [ -n "$PR_NUMBER" ]; then
    info_log "PR recorded for $TEST_NAMESPACE (number: $PR_NUMBER); cleanup will remove it"
else
    info_log "⚠️  PR not recorded for $TEST_NAMESPACE within 120s (cleanup falls back to branch lookup)"
fi

# ============================================================================
# CLEANUP: handled by trap (PR/branch/files for $TEST_NAMESPACE)
# ============================================================================
echo ""

# ============================================================================
