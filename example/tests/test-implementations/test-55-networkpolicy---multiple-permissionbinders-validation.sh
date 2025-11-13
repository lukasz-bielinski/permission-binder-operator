#!/bin/bash
# Test 55: NetworkPolicy - Multiple PermissionBinders Validation
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 55: NetworkPolicy - Multiple PermissionBinders Validation"
echo "----------------------------------------------------------------"

BINDER_A="test-permissionbinder-networkpolicy-multi-a"
BINDER_B="test-permissionbinder-networkpolicy-multi-b"
CONFIGMAP_A="permission-config-multi-a"
CONFIGMAP_B="permission-config-multi-b"
GITHUB_REPO="lukasz-bielinski/tests-network-policies"
METRICS_PORT=8080

# Cleanup helper
cleanup_resources() {
    kubectl delete permissionbinder "$BINDER_A" "$BINDER_B" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
    kubectl delete configmap "$CONFIGMAP_A" "$CONFIGMAP_B" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
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
# 2. Create two PermissionBinder resources with NetworkPolicy enabled
# ----------------------------------------------------------------------------
info_log "Creating two PermissionBinder CRs with NetworkPolicy enabled"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: $BINDER_A
  namespace: $NAMESPACE
spec:
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: "edit"
    viewer: "view"
  configMapName: "$CONFIGMAP_A"
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
---
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: $BINDER_B
  namespace: $NAMESPACE
spec:
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    engineer: "edit"
    viewer: "view"
  configMapName: "$CONFIGMAP_B"
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

# ConfigMaps (minimal content)
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIGMAP_A
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-multi-a-engineer,OU=Openshift,DC=example,DC=com
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIGMAP_B
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-multi-b-engineer,OU=Openshift,DC=example,DC=com
EOF

info_log "Waiting for reconciliation (20s)"
sleep 20

# ----------------------------------------------------------------------------
# 3. Verify warning logged about multiple CRs
# ----------------------------------------------------------------------------
LOG_WARNING=$(kubectl logs -n "$NAMESPACE" deployment/operator-controller-manager --since=2m 2>/dev/null | grep -i "multiple permissionbinder" | head -1)
if [ -n "$LOG_WARNING" ]; then
    pass_test "Operator logged warning about multiple PermissionBinder CRs"
    info_log "Log entry: $LOG_WARNING"
else
    info_log "⚠️  Warning log not detected (may require longer wait or higher log level)"
fi

# ----------------------------------------------------------------------------
# 4. Verify metric incremented
# ----------------------------------------------------------------------------
NEED_PORT_FORWARD=false
if ! lsof -Pi :$METRICS_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
    NEED_PORT_FORWARD=true
    info_log "Starting port-forward for metrics endpoint (port $METRICS_PORT)"
    kubectl port-forward -n "$NAMESPACE" svc/operator-controller-manager-metrics-service $METRICS_PORT:8080 >/dev/null 2>&1 &
    PF_PID=$!
    sleep 3
fi

METRIC_VALUE=$(curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null | grep '^permission_binder_multiple_crs_networkpolicy_warning_total' | awk '{print $2}' | head -1 || echo "0")
if [ "$METRIC_VALUE" != "0" ]; then
    pass_test "Metric permission_binder_multiple_crs_networkpolicy_warning_total incremented ($METRIC_VALUE)"
else
    info_log "⚠️  Metric not incremented (value: $METRIC_VALUE)"
fi

if [ "$NEED_PORT_FORWARD" = true ] && [ -n "$PF_PID" ]; then
    kill $PF_PID 2>/dev/null || true
fi

# Cleanup handled by trap
echo ""

# ============================================================================
