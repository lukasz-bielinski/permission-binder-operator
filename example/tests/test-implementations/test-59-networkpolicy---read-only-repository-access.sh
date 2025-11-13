#!/bin/bash
# Test 59: NetworkPolicy - Read-Only Repository Access (Forbidden)
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 59: NetworkPolicy - Read-Only Repository Access (Forbidden)"
echo "-------------------------------------------------------------------"

BINDER_NAME="test-permissionbinder-networkpolicy-readonly"
CONFIGMAP_NAME="permission-config-readonly"
SECRET_NAME="github-gitops-credentials-readonly"
TEST_NAMESPACE="test-readonly"
GITHUB_REPO="lukasz-bielinski/tests-network-policies"

cleanup_resources() {
    kubectl delete permissionbinder "$BINDER_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    kubectl delete configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    cleanup_networkpolicy_test_artifacts "$BINDER_NAME" "$TEST_NAMESPACE" "$GITHUB_REPO" 2>/dev/null || true
}

trap cleanup_resources EXIT

# ----------------------------------------------------------------------------
# 1. Create read-only credentials Secret (token without push scope)
# ----------------------------------------------------------------------------
info_log "Creating read-only GitHub credentials Secret ($SECRET_NAME)"
SECRET_TEMPLATE_FILE="$SCRIPT_DIR/../../temp/github-gitops-credentials-readonly-secret.yaml"
if [ ! -f "$SECRET_TEMPLATE_FILE" ]; then
    fail_test "Read-only GitHub credentials file not found: $SECRET_TEMPLATE_FILE"
    exit 1
fi

# Apply secret from template, updating namespace dynamically
sed "s/namespace: permissions-binder-operator/namespace: $NAMESPACE/" "$SECRET_TEMPLATE_FILE" | kubectl apply -f - >/dev/null 2>&1

# ----------------------------------------------------------------------------
# 2. Create PermissionBinder referencing read-only secret
# ----------------------------------------------------------------------------
info_log "Creating PermissionBinder $BINDER_NAME with read-only credentials"
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

# Wait for reconciliation attempt
info_log "Waiting for reconciliation (20s)"
sleep 20

# ----------------------------------------------------------------------------
# 4. Validate failure captured in status/logs/metrics
# ----------------------------------------------------------------------------
STATUS_STATE=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.networkPolicies[?(@.namespace=="'$TEST_NAMESPACE'")].state}' 2>/dev/null || echo "")
STATUS_ERROR=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.networkPolicies[?(@.namespace=="'$TEST_NAMESPACE'")].errorMessage}' 2>/dev/null || echo "")

if [ -n "$STATUS_ERROR" ]; then
    pass_test "Status error message captured: $STATUS_ERROR"
else
    info_log "⚠️  No error message present in status (state=$STATUS_STATE)"
fi

# Check operator logs for forbidden/permission message
LOG_MATCH=$(kubectl logs -n "$NAMESPACE" deployment/operator-controller-manager --since=2m 2>/dev/null | grep -i "permission\|forbidden\|403" | head -1)
if [ -n "$LOG_MATCH" ]; then
    pass_test "Operator logs include forbidden/permission detail"
else
    info_log "⚠️  Forbidden/permission log not detected"
fi

# Check Git operation error metric
METRIC_VALUE=$(curl -s http://localhost:8080/metrics 2>/dev/null | grep 'permission_binder_networkpolicy_git_operations_total' | grep 'operation="push"' | grep 'status="error"' | awk '{print $2}' | head -1 || echo "0")
if [ "$METRIC_VALUE" != "0" ]; then
    pass_test "Git operation error metric incremented (push error: $METRIC_VALUE)"
else
    info_log "⚠️  Git operation error metric did not increment"
fi

# Operator should remain available
DEPLOYMENT_READY=$(kubectl get deployment operator-controller-manager -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator deployment remains Available"
else
    fail_test "Operator deployment not available after read-only failure"
fi

echo ""

# ============================================================================
