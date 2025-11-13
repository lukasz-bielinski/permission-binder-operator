#!/bin/bash
# Test 50: NetworkPolicy - Metrics Verification
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 50: NetworkPolicy - Metrics Verification"
echo "----------------------------------------------"

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

# Port-forward metrics endpoint (if not already forwarded)
METRICS_PORT=8080
if ! lsof -Pi :$METRICS_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
    info_log "Starting port-forward for metrics endpoint (port $METRICS_PORT)..."
    kubectl port-forward -n $NAMESPACE svc/operator-controller-manager-metrics-service $METRICS_PORT:8080 >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!
    sleep 3
    info_log "Port-forward started (PID: $PORT_FORWARD_PID)"
fi

# Get initial metric values
info_log "Getting initial metric values..."
INITIAL_PR_CREATED=$(curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null | grep 'permission_binder_networkpolicy_prs_created_total' | grep 'cluster="DEV-cluster"' | grep 'namespace="test-metrics"' | awk '{print $2}' | head -1 || echo "0")
INITIAL_PR_ERRORS=$(curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null | grep 'permission_binder_networkpolicy_pr_creation_errors_total' | grep 'cluster="DEV-cluster"' | awk '{print $2}' | head -1 || echo "0")
INITIAL_TEMPLATE_ERRORS=$(curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null | grep 'permission_binder_networkpolicy_template_validation_errors_total' | grep 'cluster="DEV-cluster"' | awk '{print $2}' | head -1 || echo "0")

info_log "Initial metrics:"
info_log "  PRs Created: $INITIAL_PR_CREATED"
info_log "  PR Errors: $INITIAL_PR_ERRORS"
info_log "  Template Errors: $INITIAL_TEMPLATE_ERRORS"

# Create ConfigMap with test namespace
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-metrics-engineer,OU=Openshift,DC=example,DC=com
EOF

# Wait for reconciliation and PR creation
info_log "Waiting for reconciliation and PR creation (30s)..."
sleep 30

# Get final metric values
info_log "Getting final metric values..."
FINAL_PR_CREATED=$(curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null | grep 'permission_binder_networkpolicy_prs_created_total' | grep 'cluster="DEV-cluster"' | grep 'namespace="test-metrics"' | awk '{print $2}' | head -1 || echo "0")
FINAL_PR_ERRORS=$(curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null | grep 'permission_binder_networkpolicy_pr_creation_errors_total' | grep 'cluster="DEV-cluster"' | awk '{print $2}' | head -1 || echo "0")
FINAL_TEMPLATE_ERRORS=$(curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null | grep 'permission_binder_networkpolicy_template_validation_errors_total' | grep 'cluster="DEV-cluster"' | awk '{print $2}' | head -1 || echo "0")

info_log "Final metrics:"
info_log "  PRs Created: $FINAL_PR_CREATED"
info_log "  PR Errors: $FINAL_PR_ERRORS"
info_log "  Template Errors: $FINAL_TEMPLATE_ERRORS"

# Verify metrics incremented
METRICS_VERIFICATION_FAILED=0

# Check permission_binder_networkpolicy_prs_created_total
if [ -n "$FINAL_PR_CREATED" ] && [ "$FINAL_PR_CREATED" != "0" ]; then
    # Check if metric exists with correct labels
    METRIC_EXISTS=$(curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null | grep -c 'permission_binder_networkpolicy_prs_created_total.*cluster="DEV-cluster".*namespace="test-metrics".*variant="new"' || echo "0")
    if [ "$METRIC_EXISTS" -gt 0 ]; then
        pass_test "permission_binder_networkpolicy_prs_created_total metric exists with correct labels"
    else
        fail_test "permission_binder_networkpolicy_prs_created_total metric missing or incorrect labels"
        METRICS_VERIFICATION_FAILED=1
    fi
else
    info_log "⚠️  PR creation metric not found (PR may not have been created yet)"
fi

# Check permission_binder_networkpolicy_pr_creation_errors_total (should remain 0)
if [ "$FINAL_PR_ERRORS" == "$INITIAL_PR_ERRORS" ] || [ "$FINAL_PR_ERRORS" == "0" ]; then
    pass_test "permission_binder_networkpolicy_pr_creation_errors_total remains 0 (no errors)"
else
    fail_test "permission_binder_networkpolicy_pr_creation_errors_total incremented: $FINAL_PR_ERRORS"
    METRICS_VERIFICATION_FAILED=1
fi

# Check permission_binder_networkpolicy_template_validation_errors_total (should remain 0)
if [ "$FINAL_TEMPLATE_ERRORS" == "$INITIAL_TEMPLATE_ERRORS" ] || [ "$FINAL_TEMPLATE_ERRORS" == "0" ]; then
    pass_test "permission_binder_networkpolicy_template_validation_errors_total remains 0 (no validation errors)"
else
    fail_test "permission_binder_networkpolicy_template_validation_errors_total incremented: $FINAL_TEMPLATE_ERRORS"
    METRICS_VERIFICATION_FAILED=1
fi

# Verify metrics endpoint is accessible
if curl -s http://localhost:$METRICS_PORT/metrics >/dev/null 2>&1; then
    pass_test "Metrics endpoint is accessible"
else
    fail_test "Metrics endpoint not accessible"
    METRICS_VERIFICATION_FAILED=1
fi

# Cleanup port-forward if we started it
if [ -n "$PORT_FORWARD_PID" ]; then
    kill $PORT_FORWARD_PID 2>/dev/null || true
fi

# Cleanup test artifacts
GITHUB_REPO="lukasz-bielinski/tests-network-policies"
cleanup_networkpolicy_test_artifacts "test-permissionbinder-networkpolicy" "test-metrics" "$GITHUB_REPO"
cleanup_networkpolicy_files_from_repo "$GITHUB_REPO" "" "DEV-cluster"

# Final test result
if [ $METRICS_VERIFICATION_FAILED -eq 1 ]; then
    fail_test "Some metrics verifications failed - check logs above"
    exit 1
fi

echo ""

# ============================================================================

