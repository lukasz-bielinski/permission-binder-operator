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

set +e  # Aggregate instance exit codes; never abort the suite early

# Respect the caller's KUBECONFIG; fall back to the default k3s kubeconfig.
export KUBECONFIG="${KUBECONFIG:-$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)}"
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
POOL_A=(00 02 03 04 07 10 11 13 17 18 20 23 31 32 33 34 35 36 38 39 40 41 58)
HEAVY_PARALLEL=(24)
POOL_B=(01 05 06 08 09 14 15 19 21 22 25 26 27 28 29 30 37 42 43)
POOL_C=(60 16)

usage() {
    sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
log ""

# Explicit test subset: run it serially via the standard runner (caller picked
# the tests, so no pool scheduling is applied).
if [ ${#EXPLICIT_TESTS[@]} -gt 0 ]; then
    log "Explicit test list requested (${EXPLICIT_TESTS[*]}); running serially."
    log ""
    EXP_START=$(date +%s)
    # Legacy mode (no INSTANCE): the caller may pick pool-C tests, which rely
    # on unprefixed namespaces, fixed ClusterRole names (test 16) and the
    # legacy regex namespace sweep.
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
# depend on the legacy regex namespace sweep between tests.
"$RUNNER" "${POOL_C[@]}" >"$SERIAL_LOG" 2>&1
SERIAL_RC=$?
SERIAL_END=$(date +%s)
if [ "$SERIAL_RC" -eq 0 ]; then
    log -e "✅ Pool C finished in $((SERIAL_END - SERIAL_START))s — ${GREEN}PASS${NC}"
else
    log -e "❌ Pool C finished in $((SERIAL_END - SERIAL_START))s — ${RED}FAIL (exit $SERIAL_RC)${NC}"
fi
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
