#!/bin/bash
set -e

# Usage:
#   ./cleanup-operator.sh          # Per-test cleanup - keeps the PermissionBinder CRD
#   ./cleanup-operator.sh --full   # Full wipe - also deletes the CRD (manual resets)
#
# Per-instance isolation (set by run-tests-full-isolation.sh, all optional):
#   NAMESPACE       operator namespace to clean (default: permissions-binder-operator)
#   INSTANCE        instance id; cluster-scoped RBAC names carry a -${INSTANCE} suffix
#   TEST_NS_PREFIX  when set, only test namespaces starting with this prefix are
#                   deleted (instead of the legacy cluster-wide regex sweep)
# With none of these set the behavior is the legacy single-instance cleanup.

FULL_CLEANUP=false
for arg in "$@"; do
    case "$arg" in
        --full)
            FULL_CLEANUP=true
            ;;
        -h|--help)
            echo "Usage: $0 [--full]"
            echo "  (default)  Remove operator, its resources and test namespaces; keep the CRD"
            echo "  --full     Also delete the PermissionBinder CRD (full manual reset)"
            echo ""
            echo "Env: NAMESPACE, INSTANCE, TEST_NS_PREFIX scope the cleanup to one instance."
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $arg (use --full for a complete wipe, -h for help)"
            exit 1
            ;;
    esac
done

# Per-instance parameterization (defaults preserve the legacy behavior)
NAMESPACE="${NAMESPACE:-permissions-binder-operator}"
INSTANCE="${INSTANCE:-}"
TEST_NS_PREFIX="${TEST_NS_PREFIX:-}"
RBAC_SUFFIX=""
if [ -n "$INSTANCE" ]; then
    RBAC_SUFFIX="-${INSTANCE}"
fi

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║   🧹 Permission Binder Operator - Complete Cleanup Script     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [ "$FULL_CLEANUP" = true ]; then
    echo -e "${YELLOW}Mode: FULL cleanup (CRD will be deleted)${NC}"
else
    echo -e "${YELLOW}Mode: per-test cleanup (CRD is kept; use --full to delete it)${NC}"
fi
if [ -n "$INSTANCE" ]; then
    echo -e "${YELLOW}Instance: $INSTANCE (namespace: $NAMESPACE, test-ns prefix: ${TEST_NS_PREFIX:-<none>})${NC}"
fi
echo ""

# Check if KUBECONFIG is set
if [ -z "$KUBECONFIG" ]; then
    echo -e "${RED}ERROR: KUBECONFIG not set${NC}"
    exit 1
fi

echo "Step 1: Remove PermissionBinder CR (triggers finalizer)"
echo "--------------------------------------------------------"
kubectl get permissionbinder -n "$NAMESPACE" 2>/dev/null | grep -v NAME | awk '{print $1}' | while read pb; do
    echo "Deleting PermissionBinder: $pb"
    kubectl delete permissionbinder "$pb" -n "$NAMESPACE" --timeout=30s 2>/dev/null || true
done

echo ""
echo "Step 2: Remove finalizers from stuck PermissionBinder CRs"
echo "-----------------------------------------------------------"
kubectl get permissionbinder -n "$NAMESPACE" 2>/dev/null | grep -v NAME | awk '{print $1}' | while read pb; do
    echo "Patching finalizers for: $pb"
    kubectl patch permissionbinder "$pb" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
done

sleep 5

echo ""
echo "Step 3: Delete operator deployment"
echo "------------------------------------"
kubectl delete deployment operator-controller-manager -n "$NAMESPACE" --timeout=30s 2>/dev/null || echo "Deployment not found (OK)"

sleep 2

echo ""
echo "Step 4: Delete operator namespace resources"
echo "---------------------------------------------"
kubectl delete configmap,service,servicemonitor,serviceaccount,role,rolebinding,secret --all -n "$NAMESPACE" --timeout=30s 2>/dev/null || echo "Resources not found (OK)"
# Specifically delete GitHub credentials secret if it exists
kubectl delete secret github-gitops-credentials -n "$NAMESPACE" --timeout=30s 2>/dev/null || echo "GitHub secret not found (OK)"

sleep 2

echo ""
echo "Step 5: Delete cluster-wide resources (this instance's only)"
echo "-------------------------------------------------------------"
kubectl delete clusterrole \
    "operator-manager-role${RBAC_SUFFIX}" \
    "operator-metrics-auth-role${RBAC_SUFFIX}" \
    "operator-metrics-reader${RBAC_SUFFIX}" \
    "operator-permissionbinder-editor-role${RBAC_SUFFIX}" \
    "operator-permissionbinder-viewer-role${RBAC_SUFFIX}" \
    --ignore-not-found=true
kubectl delete clusterrolebinding \
    "operator-manager-rolebinding${RBAC_SUFFIX}" \
    "operator-metrics-auth-rolebinding${RBAC_SUFFIX}" \
    --ignore-not-found=true

if [ "$FULL_CLEANUP" = true ]; then
    echo ""
    echo "Step 6: Delete CRD (may take time)"
    echo "------------------------------------"
    kubectl delete crd permissionbinders.permission.permission-binder.io --timeout=60s 2>/dev/null || echo "CRD not found (OK)"

    sleep 3
else
    echo ""
    echo "Step 6: Delete CRD"
    echo "------------------------------------"
    echo "Skipped (CRD is installed once per suite run; use --full to delete it)"
fi

echo ""
echo "Step 7: Force delete operator namespace"
echo "-----------------------------------------"
kubectl delete namespace "$NAMESPACE" --timeout=30s 2>/dev/null || echo "Namespace not found (OK)"

# If namespace is stuck, force it
if kubectl get namespace "$NAMESPACE" 2>/dev/null | grep -q Terminating; then
    echo "Namespace stuck in Terminating - removing finalizers..."
    kubectl get namespace "$NAMESPACE" -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" -f - 2>/dev/null || true
fi

sleep 5

echo ""
echo "Step 8: Clean up test namespaces (auto-cleanup for E2E tests)"
echo "----------------------------------------------------------------------"
# When TEST_NS_PREFIX is set, delete ONLY this instance's test namespaces.
# Legacy mode (no prefix) keeps the historical cluster-wide regex sweep.
list_test_namespaces() {
    if [ -n "$TEST_NS_PREFIX" ]; then
        kubectl get ns -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | grep "^${TEST_NS_PREFIX}" || true
    else
        kubectl get ns 2>/dev/null | grep -E "(project|tenant|staging|test-|excluded-)" | awk '{print $1}' || true
    fi
}

# Batch deletion: one non-blocking kubectl call for ALL test namespaces, then
# poll until they are gone (sequential --timeout=30s deletes serialized the
# sweep at ~30s per stuck namespace).
TEST_NS_LIST=$(list_test_namespaces)
if [ -n "$TEST_NS_LIST" ]; then
    echo "$TEST_NS_LIST" | while read ns; do
        [ -z "$ns" ] && continue
        echo "Deleting test namespace: $ns"
    done
    echo "$TEST_NS_LIST" | xargs -r kubectl delete namespace --wait=false 2>/dev/null || true

    # Poll until all test namespaces are gone (up to ~90s)
    WAITED=0
    while [ "$WAITED" -lt 90 ]; do
        if [ -z "$(list_test_namespaces)" ]; then
            break
        fi
        sleep 3
        WAITED=$((WAITED + 3))
    done

    # Force delete stragglers stuck in Terminating
    list_test_namespaces | while read ns; do
        [ -z "$ns" ] && continue
        if kubectl get ns "$ns" 2>/dev/null | grep -q Terminating; then
            echo "Force deleting stuck namespace: $ns"
            kubectl delete namespace "$ns" --force --grace-period=0 2>/dev/null || true
        fi
    done
fi

DELETED_COUNT=$(list_test_namespaces | grep -c . || true)
if [ "${DELETED_COUNT:-0}" -eq 0 ]; then
    echo "✅ All test namespaces cleaned"
else
    echo "⚠️  Some test namespaces still exist: $DELETED_COUNT"
fi

echo ""
echo "Step 9: Verify cleanup"
echo "-----------------------"
sleep 5

echo -e "\n${YELLOW}Checking remaining resources:${NC}"
kubectl get ns "$NAMESPACE" 2>&1 | grep -q "NotFound" && echo -e "${GREEN}✅ Operator namespace: DELETED${NC}" || echo -e "${RED}❌ Operator namespace: STILL EXISTS${NC}"
if [ "$FULL_CLEANUP" = true ]; then
    kubectl get crd permissionbinders.permission.permission-binder.io 2>&1 | grep -q "NotFound" && echo -e "${GREEN}✅ CRD: DELETED${NC}" || echo -e "${RED}❌ CRD: STILL EXISTS${NC}"
else
    kubectl get crd permissionbinders.permission.permission-binder.io >/dev/null 2>&1 && echo -e "${GREEN}✅ CRD: PRESENT (kept by design)${NC}" || echo -e "${YELLOW}⚠️  CRD: NOT INSTALLED (runner will install it at suite start)${NC}"
fi
kubectl get clusterrole 2>/dev/null | grep -qE "^operator-manager-role${RBAC_SUFFIX}[[:space:]]" && echo -e "${RED}❌ ClusterRoles: STILL EXIST${NC}" || echo -e "${GREEN}✅ ClusterRoles: DELETED${NC}"

MANAGED_NS_COUNT=$(list_test_namespaces | grep -c . || true)
echo -e "${YELLOW}ℹ️  Managed namespaces remaining: ${MANAGED_NS_COUNT:-0}${NC}"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                   🎉 CLEANUP COMPLETE                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
