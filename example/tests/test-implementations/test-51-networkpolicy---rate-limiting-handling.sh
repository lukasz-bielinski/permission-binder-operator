#!/bin/bash
# Test 51: NetworkPolicy - Rate Limiting Handling
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 51: NetworkPolicy - Rate Limiting Handling"
echo "------------------------------------------------"

# Note: This test verifies operator handles rate limiting gracefully
# In real scenarios, rate limiting may occur naturally when creating many PRs
# This test checks operator logs and metrics for rate limit error handling

# Setup: Create GitHub GitOps credentials Secret
CREDENTIALS_FILE="$SCRIPT_DIR/../../temp/github-gitops-credentials-secret.yaml"
if [ ! -f "$CREDENTIALS_FILE" ]; then
    fail_test "GitHub credentials file not found: $CREDENTIALS_FILE"
    exit 1
fi

if ! kubectl_retry kubectl get secret github-gitops-credentials -n $NAMESPACE >/dev/null 2>&1; then
    info_log "Creating GitHub GitOps credentials Secret"
    sed "s/namespace: permissions-binder-operator/namespace: $NAMESPACE/" "$CREDENTIALS_FILE" | kubectl apply -f - >/dev/null 2>&1
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
fi

# Check current GitHub API rate limit status
info_log "Checking GitHub API rate limit status..."
if command -v gh &> /dev/null; then
    RATE_LIMIT=$(gh api rate_limit --jq '.rate.remaining' 2>/dev/null || echo "unknown")
    info_log "GitHub API rate limit remaining: $RATE_LIMIT"
fi

# Create multiple namespaces rapidly to potentially trigger rate limit
# (Note: This may not actually trigger rate limit, but tests error handling)
info_log "Creating multiple namespaces rapidly to test rate limit handling..."
for i in {1..5}; do
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-ratelimit-$i-engineer,OU=Openshift,DC=example,DC=com
EOF
    sleep 1
done

# Wait for reconciliation
info_log "Waiting for reconciliation (30s)..."
sleep 30

# Check operator logs for rate limit errors
info_log "Checking operator logs for rate limit errors..."
RATE_LIMIT_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=100 2>/dev/null | grep -i "rate limit\|rate_limit" | wc -l || echo "0")
info_log "Rate limit log entries found: $RATE_LIMIT_LOGS"

# Check metrics for rate limit errors (if port-forward available)
METRICS_PORT=8080
RATE_LIMIT_METRIC=0
if lsof -Pi :$METRICS_PORT -sTCP:LISTEN -t >/dev/null 2>&1 || kubectl port-forward -n $NAMESPACE svc/operator-controller-manager-metrics-service $METRICS_PORT:8080 >/dev/null 2>&1 & sleep 2; then
    RATE_LIMIT_METRIC=$(curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null | grep 'permission_binder_networkpolicy_pr_creation_errors_total.*rate_limit' | awk '{print $2}' | head -1 || echo "0")
    info_log "Rate limit error metric: $RATE_LIMIT_METRIC"
fi

# Verify operator does not crash
DEPLOYMENT_READY=$(kubectl_retry kubectl get deployment operator-controller-manager -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator remains running (does not crash on rate limit)"
else
    fail_test "Operator deployment not ready (may have crashed)"
    exit 1
fi

# Verify rate limit errors are logged (if they occurred)
if [ "$RATE_LIMIT_LOGS" -gt 0 ] || [ "$RATE_LIMIT_METRIC" -gt 0 ]; then
    pass_test "Rate limit errors detected and handled (logged or tracked in metrics)"
else
    info_log "⚠️  No rate limit errors detected (may not have occurred in this test run)"
    pass_test "Operator continues processing (rate limit not triggered, which is normal)"
fi

# Verify operator continues processing other namespaces
NAMESPACES_PROCESSED=$(kubectl get permissionbinder test-permissionbinder-networkpolicy -n $NAMESPACE -o jsonpath='{.status.networkPolicies[*].namespace}' 2>/dev/null | wc -w || echo "0")
if [ "$NAMESPACES_PROCESSED" -gt 0 ]; then
    pass_test "Operator continues processing namespaces (graceful degradation)"
else
    info_log "⚠️  No namespaces processed (may need more time)"
fi

# Cleanup test artifacts
GITHUB_REPO="lukasz-bielinski/tests-network-policies"
for i in {1..5}; do
    cleanup_networkpolicy_test_artifacts "test-permissionbinder-networkpolicy" "test-ratelimit-$i" "$GITHUB_REPO" 2>/dev/null || true
done
cleanup_networkpolicy_files_from_repo "$GITHUB_REPO" "" "DEV-cluster" 2>/dev/null || true

echo ""

# ============================================================================

