#!/bin/bash
set -e

# Usage:
#   ./cleanup-operator.sh          # Per-test cleanup - keeps the PermissionBinder CRD
#   ./cleanup-operator.sh --full   # Full wipe - also deletes the CRD (manual resets)

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
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $arg (use --full for a complete wipe, -h for help)"
            exit 1
            ;;
    esac
done

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
echo ""

# Check if KUBECONFIG is set
if [ -z "$KUBECONFIG" ]; then
    echo -e "${RED}ERROR: KUBECONFIG not set${NC}"
    exit 1
fi

echo "Step 1: Remove PermissionBinder CR (triggers finalizer)"
echo "--------------------------------------------------------"
kubectl get permissionbinder -n permissions-binder-operator 2>/dev/null | grep -v NAME | awk '{print $1}' | while read pb; do
    echo "Deleting PermissionBinder: $pb"
    kubectl delete permissionbinder "$pb" -n permissions-binder-operator --timeout=30s 2>/dev/null || true
done

echo ""
echo "Step 2: Remove finalizers from stuck PermissionBinder CRs"
echo "-----------------------------------------------------------"
kubectl get permissionbinder -n permissions-binder-operator 2>/dev/null | grep -v NAME | awk '{print $1}' | while read pb; do
    echo "Patching finalizers for: $pb"
    kubectl patch permissionbinder "$pb" -n permissions-binder-operator -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
done

sleep 5

echo ""
echo "Step 3: Delete operator deployment"
echo "------------------------------------"
kubectl delete deployment operator-controller-manager -n permissions-binder-operator --timeout=30s 2>/dev/null || echo "Deployment not found (OK)"

sleep 2

echo ""
echo "Step 4: Delete operator namespace resources"
echo "---------------------------------------------"
kubectl delete configmap,service,servicemonitor,serviceaccount,role,rolebinding,secret --all -n permissions-binder-operator --timeout=30s 2>/dev/null || echo "Resources not found (OK)"
# Specifically delete GitHub credentials secret if it exists
kubectl delete secret github-gitops-credentials -n permissions-binder-operator --timeout=30s 2>/dev/null || echo "GitHub secret not found (OK)"

sleep 2

echo ""
echo "Step 5: Delete cluster-wide resources"
echo "---------------------------------------"
kubectl delete clusterrole operator-manager-role operator-metrics-auth-role operator-metrics-reader operator-permissionbinder-editor-role operator-permissionbinder-viewer-role --ignore-not-found=true
kubectl delete clusterrolebinding operator-manager-rolebinding operator-metrics-auth-rolebinding --ignore-not-found=true

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
kubectl delete namespace permissions-binder-operator --timeout=30s 2>/dev/null || echo "Namespace not found (OK)"

# If namespace is stuck, force it
if kubectl get namespace permissions-binder-operator 2>/dev/null | grep -q Terminating; then
    echo "Namespace stuck in Terminating - removing finalizers..."
    kubectl get namespace permissions-binder-operator -o json | jq '.spec.finalizers = []' | kubectl replace --raw /api/v1/namespaces/permissions-binder-operator/finalize -f - 2>/dev/null || true
fi

sleep 5

echo ""
echo "Step 8: Clean up test namespaces (auto-cleanup for E2E tests)"
echo "----------------------------------------------------------------------"
# Auto-delete test namespaces without prompt for E2E test isolation
kubectl get ns 2>/dev/null | grep -E "(project|tenant|staging|test-|excluded-)" | awk '{print $1}' | while read ns; do
    echo "Deleting test namespace: $ns"
    kubectl delete namespace "$ns" --timeout=30s 2>/dev/null || true
done

# Force delete if stuck
sleep 3
kubectl get ns 2>/dev/null | grep -E "(project|tenant|staging|test-|excluded-)" | grep Terminating | awk '{print $1}' | while read ns; do
    echo "Force deleting stuck namespace: $ns"
    kubectl delete namespace "$ns" --force --grace-period=0 2>/dev/null || true
done

DELETED_COUNT=$(kubectl get ns 2>/dev/null | grep -E "(project|tenant|staging|test-|excluded-)" | wc -l)
if [ "$DELETED_COUNT" -eq 0 ]; then
    echo "✅ All test namespaces cleaned"
else
    echo "⚠️  Some test namespaces still exist: $DELETED_COUNT"
fi

echo ""
echo "Step 9: Verify cleanup"
echo "-----------------------"
sleep 5

echo -e "\n${YELLOW}Checking remaining resources:${NC}"
kubectl get ns permissions-binder-operator 2>&1 | grep -q "NotFound" && echo -e "${GREEN}✅ Operator namespace: DELETED${NC}" || echo -e "${RED}❌ Operator namespace: STILL EXISTS${NC}"
if [ "$FULL_CLEANUP" = true ]; then
    kubectl get crd permissionbinders.permission.permission-binder.io 2>&1 | grep -q "NotFound" && echo -e "${GREEN}✅ CRD: DELETED${NC}" || echo -e "${RED}❌ CRD: STILL EXISTS${NC}"
else
    kubectl get crd permissionbinders.permission.permission-binder.io >/dev/null 2>&1 && echo -e "${GREEN}✅ CRD: PRESENT (kept by design)${NC}" || echo -e "${YELLOW}⚠️  CRD: NOT INSTALLED (runner will install it at suite start)${NC}"
fi
kubectl get clusterrole | grep -q "operator-manager-role" && echo -e "${RED}❌ ClusterRoles: STILL EXIST${NC}" || echo -e "${GREEN}✅ ClusterRoles: DELETED${NC}"

MANAGED_NS_COUNT=$(kubectl get ns | grep -E "(project|tenant|staging|test-)" | wc -l)
echo -e "${YELLOW}ℹ️  Managed namespaces remaining: $MANAGED_NS_COUNT${NC}"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                   🎉 CLEANUP COMPLETE                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

