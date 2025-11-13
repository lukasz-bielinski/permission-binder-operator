#!/bin/bash
# Test 62: NetworkPolicy - High Frequency Reconciliation Stress Test
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 62: NetworkPolicy - High Frequency Reconciliation"
echo "-------------------------------------------------------"

BINDER_NAME="test-permissionbinder-networkpolicy-hfreq"
CONFIGMAP_NAME="permission-config-hfreq"
BASE_NAMESPACE="test-hfreq"
GITHUB_REPO="lukasz-bielinski/tests-network-policies"

cleanup_resources() {
    cleanup_networkpolicy_test_artifacts "$BINDER_NAME" "$BASE_NAMESPACE" "$GITHUB_REPO" 2>/dev/null || true
    for i in {1..3}; do
        cleanup_networkpolicy_test_artifacts "$BINDER_NAME" "$BASE_NAMESPACE-$i" "$GITHUB_REPO" 2>/dev/null || true
    done
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
info_log "Creating PermissionBinder $BINDER_NAME with reconciliationInterval=5s"
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
        name: "github-gitops-credentials"
        namespace: "$NAMESPACE"
    templateDir: "networkpolicies/templates"
    autoMerge:
      enabled: false
    backupExisting: true
    reconciliationInterval: "5s"
    batchProcessing:
      batchSize: 1
      sleepBetweenNamespaces: "0s"
      sleepBetweenBatches: "1s"
EOF

# Initial ConfigMap
data='CN=COMPANY-K8S-'"$BASE_NAMESPACE"'-engineer,OU=Openshift,DC=example,DC=com'
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIGMAP_NAME
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    $data
EOF

info_log "Waiting for initial reconciliation (20s)"
sleep 20

FIRST_TS=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.lastNetworkPolicyReconciliation}' 2>/dev/null || echo "")
info_log "First reconciliation timestamp: ${FIRST_TS:-<none>}"
if [ -z "$FIRST_TS" ]; then
    fail_test "First reconciliation timestamp missing"
    exit 1
fi

# ----------------------------------------------------------------------------
# 3. Rapid ConfigMap updates to stress reconciliation
# ----------------------------------------------------------------------------
for i in {1..3}; do
    info_log "Applying ConfigMap update iteration $i"
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIGMAP_NAME
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-$BASE_NAMESPACE-engineer,OU=Openshift,DC=example,DC=com
    CN=COMPANY-K8S-$BASE_NAMESPACE-$i-viewer,OU=Openshift,DC=example,DC=com
EOF
    sleep 6

done

SECOND_TS=$(kubectl get permissionbinder "$BINDER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.lastNetworkPolicyReconciliation}' 2>/dev/null || echo "")
info_log "Second reconciliation timestamp: ${SECOND_TS:-<none>}"
if [ -z "$SECOND_TS" ]; then
    fail_test "Second reconciliation timestamp missing"
    exit 1
fi

FIRST_EPOCH=$(date -d "$FIRST_TS" +%s 2>/dev/null || echo "0")
SECOND_EPOCH=$(date -d "$SECOND_TS" +%s 2>/dev/null || echo "0")

if [ "$FIRST_EPOCH" -gt 0 ] && [ "$SECOND_EPOCH" -gt "$FIRST_EPOCH" ]; then
    pass_test "LastNetworkPolicyReconciliation advanced from $FIRST_TS to $SECOND_TS"
else
    fail_test "Reconciliation timestamp did not advance (first=$FIRST_TS, second=$SECOND_TS)"
fi

DEPLOYMENT_READY=$(kubectl get deployment operator-controller-manager -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$DEPLOYMENT_READY" == "True" ]; then
    pass_test "Operator deployment remains Available under high frequency load"
else
    fail_test "Operator deployment reports unavailable under high frequency load"
fi

echo ""

# ============================================================================
