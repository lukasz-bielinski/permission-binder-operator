#!/bin/bash
# Run E2E tests in PARALLEL with test pools.
#
# Pools (from per-test classification, adversarially verified — see issue #36):
#   Pool A (25): parallel after parameterization alone
#   Pool B (19): parallel after the assertion rewrites
#   Pool C (17): serial-only — GitHub-repo-sharing NetworkPolicy tests and
#                test 16 (mutates a fixed-name ClusterRole)
#
# Scheduling:
#   - Pools A+B are sharded across N slots (default 3); each slot runs one
#     instance of run-tests-full-isolation.sh with INSTANCE=$i and its subset.
#   - Heavy tests are scheduled solo within their slot (24 creates 50
#     namespaces; 60 is a 5s-interval stress test and a bad neighbor).
#   - Pool C runs serially at the end.
#
# Usage:
#   ./run-tests-parallel.sh                  # Pools A+B across N slots, then Pool C serially
#   ./run-tests-parallel.sh --slots 4        # Use 4 parallel slots
#   ./run-tests-parallel.sh --sequential     # Sequential baseline (full isolation runner)
#   ./run-tests-parallel.sh 44 45 46         # Run only the given tests (serially)
#
# Environment:
#   E2E_WAIT_MULT   Multiplies harness-owned fixed sleeps/timeouts (default 1;
#                   the parallel runner exports a load-aware default of 1.5 when
#                   running with --slots > 1). The rpi4-class k3s API server is
#                   loaded under parallelism; the harness's kubectl_retry exists
#                   for a reason.
#   INSTANCE        Set per slot by this script; consumed by the harness
#                   parameterization (see issue #34).
#   KUBECONFIG      Kubeconfig to use (default: $HOME/.kube/config). The run
#                   exits before any cleanup when the file is unreadable or
#                   the API server does not answer `kubectl get --raw /readyz`.
#   OPERATOR_IMAGE  Run the whole suite (every slot and Pool C) against this
#                   image (repo:tag or repo@sha256:...) instead of the tag
#                   committed in example/deployment/operator-deployment.yaml;
#                   inherited by every run-tests-full-isolation.sh instance,
#                   which renders it into a per-run manifest copy (the source
#                   manifest is never modified).
#   OPERATOR_IMAGE_PULL_POLICY
#                   imagePullPolicy for the override (default: Always when
#                   OPERATOR_IMAGE is set).
#   GITHUB_GITOPS_SECRET_FILE
#                   Secret manifest with the GitHub GitOps credentials for the
#                   NetworkPolicy tests (default:
#                   <repo>/temp/github-gitops-credentials-secret.yaml).
#   GITHUB_GITOPS_READONLY_SECRET_FILE
#                   Read-only variant used by test 57 (default:
#                   <repo>/temp/github-gitops-credentials-readonly-secret.yaml).

set +e  # Aggregate instance exit codes; never abort the suite early

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ID="$(date +%Y%m%d-%H%M%S)"
RESULTS_LOG="/tmp/e2e-parallel-${SUITE_ID}.log"
RUNNER="$SCRIPT_DIR/run-tests-full-isolation.sh"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Pool classification (issue #36). Pool C stays serial; pools A+B are sharded.
# Test 24 (creates 50 namespaces) is pinned to its own slot; test 60 (5s-
# interval stress) heads Pool C so it is never a neighbor of 50/51.
# ---------------------------------------------------------------------------
POOL_A=(00 02 03 04 07 10 11 12 13 17 18 20 23 31 32 33 34 35 36 38 39 40 41 58)
HEAVY_PARALLEL=(24)
POOL_B=(01 05 06 08 09 14 15 19 21 22 25 26 27 28 29 30 37 42 43)
POOL_C=(60 16 44 45 46 47 48 49 50 51 52 53 54 55 56 57 59 61)

usage() {
    sed -n '2,49p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

log() {
    echo -e "$@" | tee -a "$RESULTS_LOG"
}

# Parse arguments
SLOTS=3
SEQUENTIAL=false
EXPLICIT_TESTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --slots)
            [ $# -ge 2 ] || { echo "ERROR: --slots requires a value"; exit 1; }
            SLOTS="$2"; shift 2 ;;
        --slots=*) SLOTS="${1#*=}"; shift ;;
        --sequential) SEQUENTIAL=true; shift ;;
        -h|--help) usage 0 ;;
        *) EXPLICIT_TESTS+=("$1"); shift ;;
    esac
done

if ! [[ "$SLOTS" =~ ^[0-9]+$ ]] || [ "$SLOTS" -lt 1 ]; then
    echo "ERROR: --slots must be a positive integer (got: $SLOTS)"
    exit 1
fi

if [ ! -x "$RUNNER" ]; then
    echo "ERROR: runner not found or not executable: $RUNNER"
    exit 1
fi

# Respect the caller's KUBECONFIG; otherwise use kubectl's default location.
# Fail early with one clear message instead of 60 failing kubectl calls. Sits
# after argument parsing so --help works without a cluster; plain echo like the
# other argument errors (no results log exists yet).
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
if [ ! -r "${KUBECONFIG%%:*}" ]; then     # KUBECONFIG may be a colon-separated list
    echo "ERROR: kubeconfig not readable: ${KUBECONFIG%%:*} (export KUBECONFIG=/path/to/kubeconfig)" >&2
    exit 1
fi
export KUBECONFIG

# Cheap validation of the runner overrides (same rules as
# run-tests-full-isolation.sh): catch them here with ONE message instead of
# N identical slot failures after the CRD install and the legacy sweep.
if [ -n "${OPERATOR_IMAGE:-}" ]; then
    if ! [[ "$OPERATOR_IMAGE" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
        echo "ERROR: OPERATOR_IMAGE contains unexpected characters: $OPERATOR_IMAGE" >&2
        exit 1
    fi
    if ! [[ "${OPERATOR_IMAGE_PULL_POLICY:-Always}" =~ ^(Always|IfNotPresent|Never)$ ]]; then
        echo "ERROR: OPERATOR_IMAGE_PULL_POLICY must be Always, IfNotPresent or Never (got: $OPERATOR_IMAGE_PULL_POLICY)" >&2
        exit 1
    fi
fi
for var in GITHUB_GITOPS_SECRET_FILE GITHUB_GITOPS_READONLY_SECRET_FILE; do
    if [ -n "${!var:-}" ] && [ ! -r "${!var}" ]; then
        echo "ERROR: $var not readable: ${!var}" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Sequential baseline mode: run the full-isolation runner as-is and record the
# wall-clock so parallel speedups can be measured against it (issue #36).
# ---------------------------------------------------------------------------
if [ "$SEQUENTIAL" = true ]; then
    log "╔═══════════════════════════════════════════════════════════════╗"
    log "║     🧪 E2E Suite — SEQUENTIAL baseline                        ║"
    log "╚═══════════════════════════════════════════════════════════════╝"
    log "Started: $(date)"
    log "Results log: $RESULTS_LOG"
    log ""
    SEQ_START=$(date +%s)
    "$RUNNER" "${EXPLICIT_TESTS[@]}" 2>&1 | tee -a "$RESULTS_LOG"
    SEQ_RC=${PIPESTATUS[0]}
    SEQ_END=$(date +%s)
    log ""
    log "Sequential wall-clock: $((SEQ_END - SEQ_START))s (exit code $SEQ_RC)"
    exit "$SEQ_RC"
fi

# ---------------------------------------------------------------------------
# Parallel mode
# ---------------------------------------------------------------------------

# Load-aware default for harness-owned waits (overridable by the caller).
if [ "$SLOTS" -gt 1 ]; then
    export E2E_WAIT_MULT="${E2E_WAIT_MULT:-1.5}"
else
    export E2E_WAIT_MULT="${E2E_WAIT_MULT:-1}"
fi

log "╔═══════════════════════════════════════════════════════════════╗"
log "║     🧪 E2E Tests — PARALLEL runner (test pools)               ║"
log "╚═══════════════════════════════════════════════════════════════╝"
log ""
log "Started: $(date)"
log "Slots: $SLOTS"
log "E2E_WAIT_MULT: $E2E_WAIT_MULT"
log "Results log: $RESULTS_LOG"
log "Kubeconfig: $KUBECONFIG (context: $(kubectl config current-context 2>/dev/null || echo '<none>'))"
if [ -n "${OPERATOR_IMAGE:-}" ]; then
    log "Operator image override: $OPERATOR_IMAGE (imagePullPolicy: ${OPERATOR_IMAGE_PULL_POLICY:-Always})"
fi
if [ -n "${GITHUB_GITOPS_SECRET_FILE:-}" ]; then
    log "GitHub GitOps secret file: $GITHUB_GITOPS_SECRET_FILE"
fi
log ""

# Explicit test subset: run it serially via the standard runner (caller picked
# the tests, so no pool scheduling is applied).
if [ ${#EXPLICIT_TESTS[@]} -gt 0 ]; then
    log "Explicit test list requested (${EXPLICIT_TESTS[*]}); running serially."
    log ""
    EXP_START=$(date +%s)
    # Legacy mode (no INSTANCE): the caller may pick pool-C tests, which rely
    # on unprefixed namespaces, fixed ClusterRole names (test 16) and the
    # legacy namespace sweep (managed-by label + anchored allow-list).
    "$RUNNER" "${EXPLICIT_TESTS[@]}" 2>&1 | tee -a "$RESULTS_LOG"
    EXP_RC=${PIPESTATUS[0]}
    EXP_END=$(date +%s)
    log ""
    log "Wall-clock: $((EXP_END - EXP_START))s (exit code $EXP_RC)"
    exit "$EXP_RC"
fi

# Verify required tools are installed
MISSING_TOOLS=()
command -v kubectl &> /dev/null || MISSING_TOOLS+=("kubectl")
command -v jq &> /dev/null || MISSING_TOOLS+=("jq")
if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    log "❌ CRITICAL: Missing required tools: ${MISSING_TOOLS[*]}"
    log "   kubectl: https://kubernetes.io/docs/tasks/tools/"
    log "   jq: sudo apt-get install jq / brew install jq / yum install jq"
    exit 1
fi

# Cluster preflight: fail BEFORE the CRD install and the legacy sweep when the
# API server is not reachable through $KUBECONFIG (the explicit-test and
# --sequential paths above delegate to the runner, which preflights itself).
if ! kubectl get --raw /readyz --request-timeout=10s >/dev/null 2>&1; then
    log "❌ PREFLIGHT: API server not ready via KUBECONFIG=$KUBECONFIG (kubectl get --raw /readyz failed)"
    exit 1
fi

# ONE-TIME SUITE SETUP: install the CRD once for the whole parallel run.
# Concurrent kubectl apply of the same CRD races on annotations (issue #32),
# so this is done here, before any instance starts. The per-instance runner
# also installs the CRD itself when run standalone.
log -e "${YELLOW}📦 Suite setup: installing PermissionBinder CRD (once)...${NC}"
if kubectl apply -f "$SCRIPT_DIR/../deployment/crd.yaml" >>"$RESULTS_LOG" 2>&1; then
    log "   ✅ CRD installed"
else
    log -e "   ${RED}❌ ERROR: Failed to install CRD (see $RESULTS_LOG)${NC}"
    exit 1
fi
log ""

# Pre-parallel legacy sweep (issue #55): per-test cleanup runs BEFORE each
# test, so the LAST pool-C test of a previous run leaves its cluster-wide
# operator running. That leftover races this run's instance operators for
# ownership (first-owner-wins -> resources get the default managed-by label
# and the instance-scoped counts read 0). Sweep it in LEGACY mode (no
# INSTANCE / TEST_NS_PREFIX env -> cleanup defaults to the
# permissions-binder-operator namespace + the managed-by label / anchored
# allow-list namespace sweep). No slot is running yet, so this is the ONE
# legacy call that may also reclaim pboN-* namespaces the leftover operator
# adopted under the default label (SWEEP_SLOT_NAMESPACES=1); every other
# legacy call (explicit lists, Pool C) keeps the parallel-slot guard.
log "🧹 Pre-parallel sweep: removing legacy (non-instance) operator leftovers..."
if SWEEP_SLOT_NAMESPACES=1 "$SCRIPT_DIR/cleanup-operator.sh" >>"/tmp/e2e-parallel-${SUITE_ID}-legacy-sweep.log" 2>&1; then
    log "   ✅ Legacy leftovers swept"
else
    log "   ⚠️  Legacy sweep had warnings (/tmp/e2e-parallel-${SUITE_ID}-legacy-sweep.log)"
fi
log ""

# ---------------------------------------------------------------------------
# Shard pools A (+solo heavy) and B across N slots in round-robin order.
# ---------------------------------------------------------------------------
declare -a SLOT_TESTS
for i in $(seq 1 "$SLOTS"); do SLOT_TESTS[$i]=""; done

# Heavy test 24 runs solo within its own slot: it creates 50 namespaces and
# would otherwise starve slot-mates on a loaded API server. Reserve that slot
# FIRST so the round-robin loops below never assign anything to it.
HEAVY_SLOT=0
if [ "$SLOTS" -ge 2 ]; then
    HEAVY_SLOT=$SLOTS
    SLOT_TESTS[$HEAVY_SLOT]="${HEAVY_PARALLEL[*]}"
fi

# next_slot <current> - advance round-robin, skipping the reserved heavy slot
next_slot() {
    local idx=$(( $1 % SLOTS + 1 ))
    if [ "$idx" -eq "$HEAVY_SLOT" ]; then
        idx=$(( idx % SLOTS + 1 ))
    fi
    echo "$idx"
}

slot_idx=1
for t in "${POOL_A[@]}"; do
    SLOT_TESTS[$slot_idx]="${SLOT_TESTS[$slot_idx]} $t"
    slot_idx=$(next_slot "$slot_idx")
done

# With a single slot there is no reserved slot; test 24 just joins the queue.
if [ "$SLOTS" -lt 2 ]; then
    SLOT_TESTS[1]="${SLOT_TESTS[1]} ${HEAVY_PARALLEL[*]}"
fi

for t in "${POOL_B[@]}"; do
    SLOT_TESTS[$slot_idx]="${SLOT_TESTS[$slot_idx]} $t"
    slot_idx=$(next_slot "$slot_idx")
done

# Launch one runner instance per slot.
declare -a SLOT_PID
declare -a SLOT_LOG
declare -a SLOT_START
PARALLEL_PHASE_START=$(date +%s)

log "────────────────────────────────────────────────────────────────"
log "Parallel phase: pools A+B across $SLOTS slot(s)"
for i in $(seq 1 "$SLOTS"); do
    tests=$(echo "${SLOT_TESTS[$i]}" | xargs)  # trim whitespace
    if [ -z "$tests" ]; then
        log "  Slot $i: (no tests assigned)"
        SLOT_PID[$i]=""
        continue
    fi
    SLOT_LOG[$i]="/tmp/e2e-parallel-${SUITE_ID}-instance-${i}.log"
    SLOT_START[$i]=$(date +%s)
    log "  Slot $i (INSTANCE=$i): $tests"
    log "    log: ${SLOT_LOG[$i]}"
    INSTANCE=$i "$RUNNER" $tests >"${SLOT_LOG[$i]}" 2>&1 &
    SLOT_PID[$i]=$!
done
log "────────────────────────────────────────────────────────────────"
log ""

# Wait for all slots and collect exit codes.
SLOTS_FAILED=0
for i in $(seq 1 "$SLOTS"); do
    [ -z "${SLOT_PID[$i]:-}" ] && continue
    wait "${SLOT_PID[$i]}"
    rc=$?
    end=$(date +%s)
    elapsed=$((end - ${SLOT_START[$i]}))
    if [ "$rc" -eq 0 ]; then
        log -e "✅ Slot $i finished in ${elapsed}s — ${GREEN}PASS${NC} (log: ${SLOT_LOG[$i]})"
    else
        log -e "❌ Slot $i finished in ${elapsed}s — ${RED}FAIL (exit $rc)${NC} (log: ${SLOT_LOG[$i]})"
        SLOTS_FAILED=$((SLOTS_FAILED + 1))
    fi
done
PARALLEL_PHASE_END=$(date +%s)
log ""
log "Parallel phase wall-clock: $((PARALLEL_PHASE_END - PARALLEL_PHASE_START))s ($SLOTS_FAILED slot(s) failed)"
log ""

# Tear down every slot's leftovers before the serial phase: the per-test
# cleanup runs BEFORE each test, so after a slot's LAST test its operator,
# CR and namespaces keep running - N leftover operators would recreate their
# whitelist namespaces during pool C and fight its legacy cleanup sweep.
log "Tearing down parallel-slot leftovers..."
for i in $(seq 1 "$SLOTS"); do
    [ -z "${SLOT_PID[$i]:-}" ] && continue
    NAMESPACE="pbo-e2e-${i}" INSTANCE="$i" TEST_NS_PREFIX="pbo${i}-" \
        "$SCRIPT_DIR/cleanup-operator.sh" >>"/tmp/e2e-parallel-${SUITE_ID}-teardown-${i}.log" 2>&1 \
        && log "  ✅ Slot $i torn down" \
        || log "  ⚠️  Slot $i teardown had warnings (/tmp/e2e-parallel-${SUITE_ID}-teardown-${i}.log)"
done
log ""

# ---------------------------------------------------------------------------
# Pool C: serial-only tests, run at the end via the standard runner.
# ---------------------------------------------------------------------------
log "────────────────────────────────────────────────────────────────"
log "Serial phase: pool C (${POOL_C[*]})"
SERIAL_LOG="/tmp/e2e-parallel-${SUITE_ID}-serial-pool-c.log"
log "  log: $SERIAL_LOG"
log "────────────────────────────────────────────────────────────────"
SERIAL_START=$(date +%s)
# Pool C runs in LEGACY mode (no INSTANCE): its tests were deliberately left
# unprefixed (serial-only), test 16 mutates the fixed-name ClusterRole that
# only exists without the -${INSTANCE} suffix, and the NetworkPolicy tests
# depend on the legacy namespace sweep (managed-by label + anchored
# allow-list) between tests.
"$RUNNER" "${POOL_C[@]}" >"$SERIAL_LOG" 2>&1
SERIAL_RC=$?
SERIAL_END=$(date +%s)
if [ "$SERIAL_RC" -eq 0 ]; then
    log -e "✅ Pool C finished in $((SERIAL_END - SERIAL_START))s — ${GREEN}PASS${NC}"
else
    log -e "❌ Pool C finished in $((SERIAL_END - SERIAL_START))s — ${RED}FAIL (exit $SERIAL_RC)${NC}"
fi
log ""

# Tear down Pool C's leftovers too (per-test cleanup runs BEFORE each test,
# so the last test's legacy operator, CR, namespaces and the
# permission-binder-operator-metrics ServiceMonitor would otherwise outlive
# the suite - issue #79 expects a full run to leave nothing behind).
log "Tearing down Pool C (legacy) leftovers..."
"$SCRIPT_DIR/cleanup-operator.sh" >>"/tmp/e2e-parallel-${SUITE_ID}-teardown-legacy.log" 2>&1 \
    && log "  ✅ Pool C leftovers torn down" \
    || log "  ⚠️  Pool C teardown had warnings (/tmp/e2e-parallel-${SUITE_ID}-teardown-legacy.log)"
log ""

# ---------------------------------------------------------------------------
# Aggregate per-instance summaries into one report.
# ---------------------------------------------------------------------------
SUITE_END=$(date +%s)
TOTAL_WALL=$((SUITE_END - PARALLEL_PHASE_START))
TOTAL_FAILED=$((SLOTS_FAILED + (SERIAL_RC != 0 ? 1 : 0)))

log "═════════════════════════════════════════════════════════════════"
log "📊 PARALLEL RUN SUMMARY"
log "═════════════════════════════════════════════════════════════════"
log ""
for i in $(seq 1 "$SLOTS"); do
    [ -z "${SLOT_PID[$i]:-}" ] && continue
    # grep -c prints the count (0 included) even when it exits non-zero, so an
    # `|| echo 0` fallback would yield "0\n0" and break arithmetic below.
    slot_pass=$(grep -c "✅ Test .* PASSED" "${SLOT_LOG[$i]}" 2>/dev/null); slot_pass=${slot_pass:-0}
    slot_fail=$(grep -c "❌ Test .* FAILED" "${SLOT_LOG[$i]}" 2>/dev/null); slot_fail=${slot_fail:-0}
    log "  Slot $i: ✅ $slot_pass passed, ❌ $slot_fail failed — ${SLOT_LOG[$i]}"
    grep -E "❌ Test [0-9]+ FAILED" "${SLOT_LOG[$i]}" 2>/dev/null | sed 's/^/    /' | tee -a "$RESULTS_LOG" >/dev/null
done
sc_pass=$(grep -c "✅ Test .* PASSED" "$SERIAL_LOG" 2>/dev/null); sc_pass=${sc_pass:-0}
sc_fail=$(grep -c "❌ Test .* FAILED" "$SERIAL_LOG" 2>/dev/null); sc_fail=${sc_fail:-0}
log "  Pool C (serial): ✅ $sc_pass passed, ❌ $sc_fail failed — $SERIAL_LOG"
grep -E "❌ Test [0-9]+ FAILED" "$SERIAL_LOG" 2>/dev/null | sed 's/^/    /' | tee -a "$RESULTS_LOG" >/dev/null
log ""

TOTAL_PASS=0
TOTAL_FAIL=0
for i in $(seq 1 "$SLOTS"); do
    [ -z "${SLOT_PID[$i]:-}" ] && continue
    p=$(grep -c "✅ Test .* PASSED" "${SLOT_LOG[$i]}" 2>/dev/null); p=${p:-0}
    f=$(grep -c "❌ Test .* FAILED" "${SLOT_LOG[$i]}" 2>/dev/null); f=${f:-0}
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
done
TOTAL_PASS=$((TOTAL_PASS + sc_pass))
TOTAL_FAIL=$((TOTAL_FAIL + sc_fail))

log "Total tests: $((TOTAL_PASS + TOTAL_FAIL)) (✅ $TOTAL_PASS passed, ❌ $TOTAL_FAIL failed)"
log "Total wall-clock: ${TOTAL_WALL}s (parallel phase: $((PARALLEL_PHASE_END - PARALLEL_PHASE_START))s, serial phase: $((SERIAL_END - SERIAL_START))s)"
log "Sequential baseline for speedup comparison: ./run-tests-parallel.sh --sequential"
log ""
log "Per-instance logs:"
for i in $(seq 1 "$SLOTS"); do
    [ -z "${SLOT_PID[$i]:-}" ] && continue
    log "  - Slot $i: ${SLOT_LOG[$i]}"
done
log "  - Pool C:  $SERIAL_LOG"
log "  - Summary: $RESULTS_LOG"
log ""
log "Completed: $(date)"
log "═════════════════════════════════════════════════════════════════"

if [ "$TOTAL_FAILED" -eq 0 ] && [ "$TOTAL_FAIL" -eq 0 ]; then
    echo ""
    echo -e "${GREEN}🎉 ALL TESTS PASSED (parallel mode, $SLOTS slots)!${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}⚠️  Parallel run had failures ($TOTAL_FAILED instance(s) failed, $TOTAL_FAIL test(s) failed)${NC}"
    exit 1
fi
