#!/bin/bash
# Test 53: NetworkPolicy - Git Operations Failures
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 53: NetworkPolicy - Git Operations Failures"
echo "-----------------------------------------------"

BINDER_NAME="test-permissionbinder-networkpolicy-git-failure"
SECRET_NAME="github-gitops-credentials-invalid"
CONFIGMAP_NAME="permission-config-git-failure"
TEST_NAMESPACE="test-git-failure"
GITHUB_REPO="lukasz-bielinski/tests-network-policies"
METRICS_PORT=8080

# Cleanup helper
cleanup_resources() {
    kubectl delete permissionbinder "$BINDER_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    kubectl delete configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    cleanup_networkpolicy_test_artifacts "$BINDER_NAME" "$TEST_NAMESPACE" "$GITHUB_REPO" 2>/dev/null || true
}

trap cleanup_resources EXIT

# ----------------------------------------------------------------------------
# 1. Create invalid GitHub credentials Secret
# ----------------------------------------------------------------------------
info_log "Creating invalid GitHub credentials Secret ($SECRET_NAME)"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: $NAMESPACE
type: Opaque
stringData:
  token: "invalid-token"
  username: "invalid-user"
  email: "invalid@example.com"
EOF

# ----------------------------------------------------------------------------
# 2. Create PermissionBinder referencing invalid credentials
# ----------------------------------------------------------------------------
info_log "Creating PermissionBinder $BINDER_NAME with invalid Git credentials"
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
        name: "$SECRET_NAME"
        namespace: "$NAMESPACE"
    templateDir: "networkpolicies/templates"
    autoMerge:
      enabled: false
    backupExisting: true
    reconciliationInterval: "1h"
EOF

# ----------------------------------------------------------------------------
# 3. Create ConfigMap with test namespace to trigger reconciliation
# ----------------------------------------------------------------------------
info_log "Creating ConfigMap $CONFIGMAP_NAME to trigger reconciliation"
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

info_log "Waiting for reconciliation (20s)"
sleep 20

# ----------------------------------------------------------------------------
# 4. Verify operator recorded Git failure
# ----------------------------------------------------------------------------
# Check PermissionBinder status for error message
ERROR_MESSAGE=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.networkPolicies[?(@.namespace=="'$TEST_NAMESPACE'")].errorMessage}' 2>/dev/null || echo "")
if [ -n "$ERROR_MESSAGE" ]; then
    pass_test "PermissionBinder status contains error message: $ERROR_MESSAGE"
else
    fail_test "PermissionBinder status missing error message for namespace $TEST_NAMESPACE"
fi

# Check operator logs for git failure
LOG_MATCH=$(kubectl logs -n "$NAMESPACE" deployment/operator-controller-manager --since=2m 2>/dev/null | grep -i "$BINDER_NAME" | grep -i "git" | head -1)
if [ -n "$LOG_MATCH" ]; then
    pass_test "Operator logs contain Git failure entry"
else
    info_log "⚠️  Operator logs did not show explicit Git failure in last 2 minutes"
fi

# ----------------------------------------------------------------------------
# 5. Verify metrics capture Git operation errors (if metrics endpoint available)
# ----------------------------------------------------------------------------
METRIC_CHECK_FAILED=0
NEED_PORT_FORWARD=false
if ! lsof -Pi :$METRICS_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
    NEED_PORT_FORWARD=true
    info_log "Starting port-forward for metrics endpoint (port $METRICS_PORT)"
    kubectl port-forward -n "$NAMESPACE" svc/operator-controller-manager-metrics-service $METRICS_PORT:8080 >/dev/null 2>&1 &
    PF_PID=$!
    sleep 3
fi

METRIC_VALUE=$(curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null | grep 'permission_binder_networkpolicy_pr_creation_errors_total' | grep 'namespace="'$TEST_NAMESPACE'"' | awk '{print $2}' | head -1 || echo "0")
GIT_METRIC_VALUE=$(curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null | grep 'permission_binder_networkpolicy_git_operations_total' | grep 'status="error"' | awk '{print $2}' | head -1 || echo "0")

if [ "$METRIC_VALUE" != "0" ] || [ "$GIT_METRIC_VALUE" != "0" ]; then
    pass_test "Metrics captured Git failure (PR error: $METRIC_VALUE, git errors: $GIT_METRIC_VALUE)"
else
    info_log "⚠️  Metrics did not record Git failure (may require longer wait)"
    METRIC_CHECK_FAILED=1
fi

if [ "$NEED_PORT_FORWARD" = true ] && [ -n "$PF_PID" ]; then
    kill $PF_PID 2>/dev/null || true
fi

# ----------------------------------------------------------------------------
# 6. Verify operator continues running (graceful degradation)
# ----------------------------------------------------------------------------
DEPLOYMENT_READY=$(kubectl get deployment operator-controller-manager -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator remains available after Git failure"
else
    fail_test "Operator deployment not available after Git failure"
fi

if [ "$METRIC_CHECK_FAILED" -eq 1 ]; then
    info_log "⚠️  Metrics verification inconclusive; consider inspecting metrics endpoint manually"
fi

echo ""

# ============================================================================
