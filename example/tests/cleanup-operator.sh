#!/bin/bash
set -e

# Usage:
#   ./cleanup-operator.sh                         # Per-test cleanup - keeps the PermissionBinder CRD
#   ./cleanup-operator.sh --full                  # Full wipe - also deletes the CRD (manual resets)
#   ./cleanup-operator.sh --list-test-namespaces  # Dry run: print what Step 8 would delete, change nothing
#
# Per-instance isolation (set by run-tests-full-isolation.sh, all optional):
#   NAMESPACE         operator namespace to clean (default: permissions-binder-operator)
#   INSTANCE          instance id; cluster-scoped RBAC names carry a -${INSTANCE} suffix
#   TEST_NS_PREFIX    when set, only test namespaces starting with this prefix are
#                     deleted (instead of the legacy sweep: managed-by label +
#                     anchored allow-list, minus protected namespaces - see Step 8)
#   MANAGED_BY_VALUE  managed-by label value stamped by this instance's operator
#                     (default permission-binder-operator; with INSTANCE set it
#                     is always permission-binder-operator-${INSTANCE}, exactly
#                     as test-common.sh derives it)
#   SWEEP_SLOT_NAMESPACES=1
#                     legacy mode only: also delete parallel-slot namespaces
#                     (pbo-e2e-N, pboN-*) that the label / allow-list halves
#                     select. Set ONLY when no slot can be running (the
#                     pre-parallel sweep in run-tests-parallel.sh).
# With none of these set the behavior is the legacy single-instance cleanup.

FULL_CLEANUP=false
LIST_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --full)
            FULL_CLEANUP=true
            ;;
        --list-test-namespaces)
            LIST_ONLY=true
            ;;
        -h|--help)
            echo "Usage: $0 [--full | --list-test-namespaces]"
            echo "  (default)               Remove operator, its resources and test namespaces; keep the CRD"
            echo "  --full                  Also delete the PermissionBinder CRD (full manual reset)"
            echo "  --list-test-namespaces  Dry run: print the test namespaces Step 8 would delete"
            echo "                          (one per line on stdout; skipped protected / parallel-slot"
            echo "                          namespaces and the kubeconfig in use on stderr; exits non-zero"
            echo "                          when the cluster cannot be listed)"
            echo ""
            echo "Env: NAMESPACE, INSTANCE, TEST_NS_PREFIX, MANAGED_BY_VALUE scope the cleanup to one instance;"
            echo "     SWEEP_SLOT_NAMESPACES=1 lifts the legacy-mode parallel-slot guard (see header)."
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $arg (use --full for a complete wipe, --list-test-namespaces for a dry run, -h for help)"
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
# Label value stamped by THIS instance's operator - the SAME derivation and
# precedence as test-common.sh (env override honoured in legacy mode only; an
# INSTANCE always wins, so both scripts agree on what "this instance" owns).
MANAGED_BY_VALUE="${MANAGED_BY_VALUE:-permission-binder-operator}"
if [ -n "$INSTANCE" ]; then
    MANAGED_BY_VALUE="permission-binder-operator-${INSTANCE}"
fi
MANAGED_BY_LABEL="permission-binder.io/managed-by=${MANAGED_BY_VALUE}"

# ---------------------------------------------------------------------------
# Test namespace selection (used by Step 8, Step 9 and --list-test-namespaces)
#
# Instance mode (TEST_NS_PREFIX set): every namespace starting with the prefix.
# Legacy mode (no prefix): the UNION of
#   (a) namespaces labelled managed-by=<MANAGED_BY_VALUE>, i.e. everything the
#       e2e operator created or adopted from whitelist entries, and
#   (b) an ANCHORED allow-list of the names the test bodies create themselves
#       (kubectl create namespace / YAML - those carry no label),
# MINUS protected namespaces (below). Both halves are anchored on the name
# column; the historical `kubectl get ns | grep -E "(project|tenant|staging|test-|excluded-)"`
# matched whole lines anywhere and could delete unrelated cluster namespaces
# while missing test4-new-namespace, valid-test17-ns, ldap-mock, ... (issue #78).
#
# Inventory (legacy names, TEST_NS_PREFIX empty), derived from
#   grep -rhoE 'TEST_NS_PREFIX\}[a-z0-9-]+' test-implementations/*.sh | sort -u
# plus every `kubectl create namespace` and unprefixed literal in the tests:
#   test-namespace-001 (00/03)  test-namespace (01)  excluded-test-ns (03)
#   test4-new-namespace (04)  project3 (05)  project1 (10)
#   valid-test17-ns another-valid-test17 (17)  large-project-1..50 (24)
#   metrics-test-ns27 (27)  sa-test-31..41 sa-test-37-b sa-test-39-empty (31-41)
#   test-hyphenated (42)  valid-invalid-test valid-invalid-test-2 stress-invalid-test (43)
#   np-test-44 np-test-44-2 np-test-45-backup np-test-46..50 np-test-51-r1..5
#   np-test-52-variant-c (44-52)  test-git-failure (53, unprefixed literal)
#   np-test-54 np-test-55-a/b np-test-56..58 np-test-59-a/b np-test-60 np-test-60-1..3 (54-60)
#   ldap-mock ldap-test-61 (61)
# Not created (invalid whitelist entries): incomplete (20), ns-unknownrole (43).
# kube-system (47) is ADOPTED via the whitelist, never created: protected below.
#
# New tests: name namespaces "${TEST_NS_PREFIX}test-NN-<slug>" (covered by the
# test-?[0-9]+-... family) or extend TEST_NS_ALLOWLIST in the same PR
# (see ADDING_NEW_TESTS.md, "Test namespace naming").
# ---------------------------------------------------------------------------
TEST_NS_ALLOWLIST='^(test-namespace(-[0-9]{3})?|test-?[0-9]+-[a-z0-9-]+|test-hyphenated|test-git-failure|excluded-test-ns|valid-invalid-test(-2)?|stress-invalid-test|valid-test17-ns|another-valid-test17|project[0-9]+|large-project-[0-9]+|metrics-test-ns[0-9]+|sa-test-[0-9]+(-[a-z0-9]+)?|np-test-[0-9]+(-[a-z0-9-]+)?|ldap-mock|ldap-test-[0-9]+(-[a-z0-9]+)?)$'

# Never deleted, whichever half selected them (plus $NAMESPACE, owned by Step 7).
PROTECTED_NS_PATTERN='^(kube-.*|default|monitoring|argocd.*|metallb-system|cattle-.*|openshift-.*|permission-binder-.*)$'
# Legacy mode only: a parallel slot's namespaces (operator pbo-e2e-N, tests
# pboN-*) may belong to a run that is still going - only that slot's own
# prefixed cleanup touches them. They reach the label half when a leftover
# legacy operator adopted a slot namespace under the default label (issue #55);
# SWEEP_SLOT_NAMESPACES=1 lifts the guard for the one legacy call where no slot
# can be running (the pre-parallel sweep in run-tests-parallel.sh). Without it
# a slot namespace leaked that way is reclaimed only when that slot number runs
# again (its own prefixed cleanup).
SIBLING_NS_PATTERN='^(pbo-e2e-.*|pbo[0-9]+-.*)$'
SWEEP_SLOT_NAMESPACES="${SWEEP_SLOT_NAMESPACES:-0}"

is_protected_namespace() { [[ "$1" =~ $PROTECTED_NS_PATTERN ]] || [ "$1" = "$NAMESPACE" ]; }
is_sibling_namespace()   { [ -z "$TEST_NS_PREFIX" ] && [ "$SWEEP_SLOT_NAMESPACES" != 1 ] && [[ "$1" =~ $SIBLING_NS_PATTERN ]]; }
# Keep every `|| true`: the script runs under `set -e` and var=$(cmd) aborts on
# a grep that matches nothing.
all_namespaces()     { kubectl get ns -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null || true; }
managed_namespaces() { kubectl get ns -l "$MANAGED_BY_LABEL" -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null || true; }

# list_test_namespaces [quiet] - the namespaces Step 8 deletes, one per line.
# Skip notices go to stderr on the first call and in the dry run; the Step 8
# polling loop and the final counts pass "quiet" so they are not repeated.
list_test_namespaces() {
    local quiet="${1:-}" candidates managed="" ns
    if [ -n "$TEST_NS_PREFIX" ]; then
        candidates=$(all_namespaces | grep "^${TEST_NS_PREFIX}" || true)
    else
        managed=$(managed_namespaces)
        candidates=$( { echo "$managed"; all_namespaces | grep -E "$TEST_NS_ALLOWLIST" || true; } | sort -u )
    fi
    for ns in $candidates; do
        if is_protected_namespace "$ns"; then
            if [ -z "$quiet" ]; then
                if grep -qx "$ns" <<<"$managed"; then
                    echo "  🛡️  protected namespace carries this instance's managed-by label: operator marks and managed RoleBindings are stripped, the namespace is never deleted: $ns" >&2
                else
                    echo "  🛡️  protected namespace skipped: $ns" >&2
                fi
            fi
            continue
        fi
        if is_sibling_namespace "$ns"; then
            if [ -z "$quiet" ]; then
                echo "  🛡️  parallel-slot namespace skipped (its own prefixed cleanup owns it; SWEEP_SLOT_NAMESPACES=1 overrides): $ns" >&2
            fi
            continue
        fi
        echo "$ns"
    done
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# KUBECONFIG: the runner exports its resolved value; when run standalone fall
# back to kubectl's default location. Fail BEFORE touching anything when the
# file is unreadable or the API server does not answer: every delete below is
# "|| echo (OK)"-guarded and the final banner is unconditional, so without this
# a dead or wrong cluster would still end in "CLEANUP COMPLETE" - and the
# helpers above swallow kubectl errors, so a dry run against an unreachable
# cluster would print a false "nothing to delete".
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
if [ ! -r "${KUBECONFIG%%:*}" ]; then     # KUBECONFIG may be a colon-separated list
    echo -e "${RED}ERROR: kubeconfig not readable: ${KUBECONFIG%%:*} (export KUBECONFIG=/path/to/kubeconfig)${NC}" >&2
    exit 1
fi
export KUBECONFIG
# Three probes 5s apart: the runner calls this before EVERY test, so a single
# 10s blip must not turn into an all-or-nothing skipped cleanup.
READYZ_OK=false
for readyz_attempt in 1 2 3; do
    if kubectl get --raw /readyz --request-timeout=10s >/dev/null 2>&1; then
        READYZ_OK=true
        break
    fi
    [ "$readyz_attempt" -lt 3 ] && sleep 5
done
if [ "$READYZ_OK" != true ]; then
    echo -e "${RED}ERROR: API server not ready via KUBECONFIG=$KUBECONFIG (kubectl get --raw /readyz failed 3 times)${NC}" >&2
    exit 1
fi
# Say which cluster is about to be swept (this script deletes namespaces by
# managed-by label / allow-list and, with --full, the CRD - the default
# kubeconfig may not be the cluster the caller had in mind).
kubeconfig_banner() { echo "Kubeconfig: $KUBECONFIG (context: $(kubectl config current-context 2>/dev/null || echo '<none>'))"; }

# Dry run: print what Step 8 would delete and exit without touching anything.
# stdout carries only namespace names; the cluster in use goes to stderr.
if [ "$LIST_ONLY" = true ]; then
    kubeconfig_banner >&2
    list_test_namespaces
    exit 0
fi

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║   🧹 Permission Binder Operator - Complete Cleanup Script     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [ "$FULL_CLEANUP" = true ]; then
    echo -e "${YELLOW}Mode: FULL cleanup (CRD will be deleted)${NC}"
else
    echo -e "${YELLOW}Mode: per-test cleanup (CRD is kept; use --full to delete it)${NC}"
fi
if [ -n "$INSTANCE" ]; then
    echo -e "${YELLOW}Instance: $INSTANCE (namespace: $NAMESPACE, test-ns prefix: ${TEST_NS_PREFIX:-<none>})${NC}"
fi
echo ""
kubeconfig_banner
echo ""

# PermissionBinder deletion MUST complete (verified gone) BEFORE the operator
# deployment is removed: once the operator is gone nothing processes the PB
# finalizers, the CRs stay Terminating forever and the namespace deletion in
# Step 7 wedges on them (issue #59). The finalizer-strip fallback below also
# covers PBs stranded inside an already-Terminating namespace from a previous
# failed cleanup (patch works in Terminating namespaces; create does not).

list_permissionbinders() {
    kubectl get permissionbinder -n "$NAMESPACE" -o name 2>/dev/null || true
}

echo "Step 1: Remove PermissionBinder CRs (triggers finalizer)"
echo "--------------------------------------------------------"
list_permissionbinders | while read pb; do
    [ -z "$pb" ] && continue
    echo "Deleting PermissionBinder: $pb"
    kubectl delete "$pb" -n "$NAMESPACE" --wait=false 2>/dev/null || true
done

echo ""
echo "Step 2: Wait until every PermissionBinder is gone (finalizer-strip fallback)"
echo "-----------------------------------------------------------------------------"
# Give the still-running operator up to 20s to process finalizers normally,
# then strip finalizers from whatever is stuck and keep polling (up to 60s).
PB_WAITED=0
while [ "$PB_WAITED" -lt 60 ]; do
    REMAINING_PBS=$(list_permissionbinders)
    if [ -z "$REMAINING_PBS" ]; then
        break
    fi
    if [ "$PB_WAITED" -ge 20 ]; then
        echo "$REMAINING_PBS" | while read pb; do
            [ -z "$pb" ] && continue
            echo "Stripping finalizers from stuck: $pb"
            kubectl patch "$pb" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        done
    fi
    sleep 3
    PB_WAITED=$((PB_WAITED + 3))
done

REMAINING_PBS=$(list_permissionbinders)
if [ -z "$REMAINING_PBS" ]; then
    echo "✅ All PermissionBinders deleted"
else
    # Last resort: strip finalizers once more so the namespace can terminate
    echo -e "${YELLOW}⚠️  PermissionBinders still present after ${PB_WAITED}s; stripping finalizers once more${NC}"
    echo "$REMAINING_PBS" | while read pb; do
        [ -z "$pb" ] && continue
        kubectl patch "$pb" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        kubectl delete "$pb" -n "$NAMESPACE" --wait=false 2>/dev/null || true
    done
    sleep 3
    if [ -z "$(list_permissionbinders)" ]; then
        echo "✅ All PermissionBinders deleted (after finalizer strip)"
    else
        echo -e "${RED}❌ PermissionBinders still present; namespace deletion may hang${NC}"
    fi
fi

echo ""
echo "Step 3: Delete operator deployment"
echo "------------------------------------"
kubectl delete deployment operator-controller-manager -n "$NAMESPACE" --timeout=30s 2>/dev/null || echo "Deployment not found (OK)"

sleep 2

echo ""
echo "Step 4: Delete operator namespace resources"
echo "---------------------------------------------"
kubectl delete configmap,service,serviceaccount,role,rolebinding,secret --all -n "$NAMESPACE" --timeout=30s 2>/dev/null || echo "Resources not found (OK)"
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
# The ServiceMonitor the runner applies lives OUTSIDE $NAMESPACE, in the shared
# "monitoring" namespace (where Prometheus discovers it), with a per-instance
# name; guard on the CRD so clusters without prometheus-operator stay quiet.
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    # --ignore-not-found makes a missing object exit 0, so the fallback fires
    # only on real errors (RBAC, timeout, API group down): keep stderr visible
    # instead of reporting a leaked ServiceMonitor as fine.
    kubectl delete servicemonitor "permission-binder-operator-metrics${RBAC_SUFFIX}" -n monitoring \
        --ignore-not-found=true --timeout=30s || echo "⚠️  ServiceMonitor delete failed (see above)"
fi

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
# Selection: list_test_namespaces() at the top of the file - this instance's
# TEST_NS_PREFIX, or in legacy mode the managed-by label + anchored allow-list,
# minus protected namespaces.

# Protected namespaces adopted by a test (47 whitelists kube-system) keep the
# operator's ownership marks and a managed RoleBinding: strip both, never
# delete. Label-scoped, so only objects this instance's operator created are
# touched. Runs first so the namespace drops out of the selection below.
for ns in $(managed_namespaces); do
    is_protected_namespace "$ns" || continue
    echo "Stripping operator marks from protected namespace: $ns"
    kubectl delete rolebinding -n "$ns" -l "$MANAGED_BY_LABEL" --ignore-not-found=true 2>/dev/null || true
    # Merge patch with null values: removes the keys, never fails on a missing one.
    kubectl patch ns "$ns" --type=merge -p '{"metadata":{"labels":{"permission-binder.io/managed-by":null},"annotations":{"permission-binder.io/managed-by":null,"permission-binder.io/created-at":null,"permission-binder.io/permission-binder":null,"permission-binder.io/permission-binder-namespace":null,"permission-binder.io/orphaned-at":null,"permission-binder.io/orphaned-by":null}}}' >/dev/null 2>&1 || true
done

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
        if [ -z "$(list_test_namespaces quiet)" ]; then
            break
        fi
        sleep 3
        WAITED=$((WAITED + 3))
    done

    # Force delete stragglers stuck in Terminating
    list_test_namespaces quiet | while read ns; do
        [ -z "$ns" ] && continue
        if kubectl get ns "$ns" 2>/dev/null | grep -q Terminating; then
            echo "Force deleting stuck namespace: $ns"
            kubectl delete namespace "$ns" --force --grace-period=0 2>/dev/null || true
        fi
    done
fi

DELETED_COUNT=$(list_test_namespaces quiet | grep -c . || true)
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

MANAGED_NS_COUNT=$(list_test_namespaces quiet | grep -c . || true)
echo -e "${YELLOW}ℹ️  Managed namespaces remaining: ${MANAGED_NS_COUNT:-0}${NC}"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                   🎉 CLEANUP COMPLETE                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
