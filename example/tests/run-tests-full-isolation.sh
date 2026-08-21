#!/bin/bash
# Run E2E tests with FULL ISOLATION
# Each test gets: fresh cluster cleanup + fresh operator deployment + test execution
# The PermissionBinder CRD is installed ONCE per suite run (cluster-scoped and
# shared by all tests); per-test cleanup/deploy never touches it.
#
# Usage:
#   ./run-tests-full-isolation.sh           # Run all tests
#   ./run-tests-full-isolation.sh 44        # Run single test
#   ./run-tests-full-isolation.sh 44 45 46  # Run specific tests
#
# Per-instance isolation (for parallel test slots):
#   INSTANCE=1 ./run-tests-full-isolation.sh ...
# When INSTANCE is set, the harness derives an isolated operator namespace,
# test-namespace prefix and scratch/log directory so that one instance's
# cleanup never touches another instance's resources:
#   NAMESPACE=pbo-e2e-${INSTANCE}
#   TEST_NS_PREFIX=pbo${INSTANCE}-
#   RUN_DIR=/tmp/pbo-e2e-${INSTANCE}/
# Without INSTANCE the behavior is exactly as before (defaults below).

set +e  # Don't exit on errors - we want to run all tests

# Respect the caller's KUBECONFIG; fall back to the default k3s kubeconfig.
export KUBECONFIG="${KUBECONFIG:-$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-instance isolation settings (defaults preserve current behavior).
if [ -n "${INSTANCE:-}" ]; then
    NAMESPACE="pbo-e2e-${INSTANCE}"
    TEST_NS_PREFIX="pbo${INSTANCE}-"
    RUN_DIR="/tmp/pbo-e2e-${INSTANCE}"
else
    NAMESPACE="permissions-binder-operator"
    TEST_NS_PREFIX=""
    RUN_DIR="/tmp"
fi
mkdir -p "$RUN_DIR"

# Export early: cleanup-operator.sh (Step 1 of every test) and the test bodies
# all scope themselves by these.
export NAMESPACE TEST_NS_PREFIX RUN_DIR INSTANCE

RESULTS_LOG="$RUN_DIR/e2e-full-isolation-$(date +%Y%m%d-%H%M%S).log"
TEST_RESULTS="$RUN_DIR/e2e-test-results-$(date +%Y%m%d-%H%M%S).log"

# Source common functions
source "$SCRIPT_DIR/test-common.sh"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test implementations directory
TEST_IMPL_DIR="$SCRIPT_DIR/test-implementations"

# Map test IDs to test files
get_test_file() {
    local test_id=$1
    if [ "$test_id" == "pre" ] || [ "$test_id" == "00" ]; then
        echo "test-00-pre-test.sh"
    elif [[ "$test_id" =~ ^[0-9]+$ ]]; then
        printf "test-%02d-*.sh" "$test_id"
    else
        echo ""
    fi
}

# Get test name from scenario file
get_test_name() {
    local test_id=$1
    if [ "$test_id" == "pre" ] || [ "$test_id" == "00" ]; then
        echo "Pre-Test: Initial State Verification"
    elif [[ "$test_id" =~ ^[0-9]+$ ]]; then
        # Try to get from scenario file
        scenario_file="$SCRIPT_DIR/scenarios/$(printf "%02d" "$test_id")-*.md"
        if ls $scenario_file 1> /dev/null 2>&1; then
            grep "^### Test $test_id:" "$(ls $scenario_file | head -1)" 2>/dev/null | sed "s/^### Test $test_id: //" | head -1
        else
            echo "Test $test_id"
        fi
    else
        echo "Test $test_id"
    fi
}

# Discover available numeric tests based on implementation files
AVAILABLE_NUMERIC_TESTS=()
for test_path in "$TEST_IMPL_DIR"/test-*-*.sh; do
    [ -f "$test_path" ] || continue
    test_filename=$(basename "$test_path")
    test_number=${test_filename#test-}
    test_number=${test_number%%-*}
    if [[ "$test_number" =~ ^[0-9]+$ ]]; then
        AVAILABLE_NUMERIC_TESTS+=("$test_number")
    fi
done

if [ ${#AVAILABLE_NUMERIC_TESTS[@]} -gt 0 ]; then
    mapfile -t AVAILABLE_NUMERIC_TESTS < <(printf "%s\n" "${AVAILABLE_NUMERIC_TESTS[@]}" | sort -n | uniq)
fi

# Get test list
if [ $# -eq 0 ]; then
    TEST_LIST=()
    if [ -f "$TEST_IMPL_DIR/test-00-pre-test.sh" ]; then
        TEST_LIST+=(pre)
    fi
    for test_id in "${AVAILABLE_NUMERIC_TESTS[@]}"; do
        (( test_id == 0 )) && continue
        TEST_LIST+=("$test_id")
    done
    if [ ${#TEST_LIST[@]} -eq 0 ]; then
        echo "❌ No test implementations found in $TEST_IMPL_DIR"
        exit 1
    fi
else
    # Run specified tests
    TEST_LIST=("$@")
fi

# Verify required tools are installed
MISSING_TOOLS=()
if ! command -v kubectl &> /dev/null; then
    MISSING_TOOLS+=("kubectl")
fi
if ! command -v jq &> /dev/null; then
    MISSING_TOOLS+=("jq")
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo "❌ CRITICAL: Missing required tools:" | tee $RESULTS_LOG
    for tool in "${MISSING_TOOLS[@]}"; do
        echo "   - $tool" | tee -a $RESULTS_LOG
    done
    echo "" | tee -a $RESULTS_LOG
    echo "📦 Installation instructions:" | tee -a $RESULTS_LOG
    if [[ " ${MISSING_TOOLS[@]} " =~ " jq " ]]; then
        echo "   jq: sudo apt-get install jq  # Debian/Ubuntu" | tee -a $RESULTS_LOG
        echo "        brew install jq          # macOS" | tee -a $RESULTS_LOG
        echo "        yum install jq           # RHEL/CentOS" | tee -a $RESULTS_LOG
    fi
    if [[ " ${MISSING_TOOLS[@]} " =~ " kubectl " ]]; then
        echo "   kubectl: https://kubernetes.io/docs/tasks/tools/" | tee -a $RESULTS_LOG
    fi
    echo "" | tee -a $RESULTS_LOG
    echo "❌ Tests cannot run without required tools. Please install missing tools and try again." | tee -a $RESULTS_LOG
    exit 1
fi

echo "╔═══════════════════════════════════════════════════════════════╗" | tee $RESULTS_LOG
echo "║     🧪 E2E Tests with FULL ISOLATION                          ║" | tee -a $RESULTS_LOG
echo "╚═══════════════════════════════════════════════════════════════╝" | tee -a $RESULTS_LOG
echo "" | tee -a $RESULTS_LOG
echo "Started: $(date)" | tee -a $RESULTS_LOG
echo "Tests to run: ${#TEST_LIST[@]}" | tee -a $RESULTS_LOG
echo "Tests: ${TEST_LIST[*]}" | tee -a $RESULTS_LOG
echo "Results log: $RESULTS_LOG" | tee -a $RESULTS_LOG
if [ -n "${INSTANCE:-}" ]; then
    echo "Instance: $INSTANCE" | tee -a $RESULTS_LOG
    echo "Operator namespace: $NAMESPACE" | tee -a $RESULTS_LOG
    echo "Test namespace prefix: $TEST_NS_PREFIX" | tee -a $RESULTS_LOG
    echo "Run dir: $RUN_DIR" | tee -a $RESULTS_LOG
fi
echo "" | tee -a $RESULTS_LOG

declare -A results
declare -A test_names
declare -A pod_names
passed=0
failed=0
current=0

# Per-instance rendered manifests live under $RUN_DIR so parallel instances
# never overwrite each other's copies. In default mode these point at the
# source manifests (no rendering needed).
DEPLOYMENT_MANIFEST="$SCRIPT_DIR/../deployment/operator-deployment.yaml"
SERVICEMONITOR_MANIFEST="$SCRIPT_DIR/../deployment/servicemonitor.yaml"

# Render the deployment manifest for this instance: point every namespace
# field at $NAMESPACE and suffix the cluster-scoped RBAC objects (ClusterRoles
# and ClusterRoleBindings, including their roleRefs and subject namespaces)
# with -$INSTANCE so instances never share or clobber them.
render_instance_manifests() {
    DEPLOYMENT_MANIFEST="$RUN_DIR/operator-deployment-${INSTANCE}.yaml"
    SERVICEMONITOR_MANIFEST="$RUN_DIR/servicemonitor-${INSTANCE}.yaml"

    # Namespace fields: the Namespace object's name plus every "namespace:"
    # reference (ServiceAccount, Role, RoleBindings, CRB subjects, Service,
    # Deployment). Names of namespaced objects are intentionally untouched.
    sed -e "s/^  name: permissions-binder-operator\$/  name: ${NAMESPACE}/" \
        -e "s/^  namespace: permissions-binder-operator\$/  namespace: ${NAMESPACE}/" \
        -e "s/^  name: operator-manager-role\$/  name: operator-manager-role-${INSTANCE}/" \
        -e "s/^  name: operator-metrics-auth-role\$/  name: operator-metrics-auth-role-${INSTANCE}/" \
        -e "s/^  name: operator-metrics-reader\$/  name: operator-metrics-reader-${INSTANCE}/" \
        -e "s/^  name: operator-permissionbinder-editor-role\$/  name: operator-permissionbinder-editor-role-${INSTANCE}/" \
        -e "s/^  name: operator-permissionbinder-viewer-role\$/  name: operator-permissionbinder-viewer-role-${INSTANCE}/" \
        -e "s/^  name: operator-manager-rolebinding\$/  name: operator-manager-rolebinding-${INSTANCE}/" \
        -e "s/^  name: operator-metrics-auth-rolebinding\$/  name: operator-metrics-auth-rolebinding-${INSTANCE}/" \
        "$SCRIPT_DIR/../deployment/operator-deployment.yaml" \
        | sed -e "/^        env:\$/a\\
        - name: MANAGED_BY_VALUE\\
          value: \"permission-binder-operator-${INSTANCE}\"" \
        > "$DEPLOYMENT_MANIFEST"
    # Note: WATCH_NAMESPACE is deliberately NOT set for e2e instances - test
    # namespaces are created dynamically from the whitelist, so a static cache
    # scope would blind the operator to them. Isolation comes from the unique
    # MANAGED_BY_VALUE plus the namespace-aware ownership annotations (PR #38).

    # ServiceMonitor: unique name and point namespaceSelector at this instance's
    # operator namespace. It stays in the shared "monitoring" namespace (where
    # Prometheus discovers it); only the selector is per-instance.
    sed -e "s/^  name: permission-binder-operator-metrics\$/  name: permission-binder-operator-metrics-${INSTANCE}/" \
        -e "s/^    - permissions-binder-operator\$/    - ${NAMESPACE}/" \
        "$SCRIPT_DIR/../deployment/servicemonitor.yaml" > "$SERVICEMONITOR_MANIFEST"
}

if [ -n "${INSTANCE:-}" ]; then
    render_instance_manifests
fi

# ONE-TIME SUITE SETUP: Install the PermissionBinder CRD once for the whole run.
# The CRD is cluster-scoped and shared by every test, so there is no need to
# delete/re-apply it per test (delete cascades all CRs and can hang on
# finalizers). Per-test cleanup keeps the CRD; use `cleanup-operator.sh --full`
# for a manual full wipe.
echo -e "${YELLOW}📦 Suite setup: installing PermissionBinder CRD (once)...${NC}" | tee -a $RESULTS_LOG
if kubectl apply -f "$SCRIPT_DIR/../deployment/crd.yaml" >>$RESULTS_LOG 2>&1; then
    echo "   ✅ CRD installed" | tee -a $RESULTS_LOG
else
    echo -e "   ${RED}❌ ERROR: Failed to install CRD (see $RESULTS_LOG)${NC}" | tee -a $RESULTS_LOG
    exit 1
fi
echo "" | tee -a $RESULTS_LOG

# Pre-load test names
for test_id in "${TEST_LIST[@]}"; do
    test_names[$test_id]=$(get_test_name $test_id)
done

# Run each test with FULL ISOLATION
for test_id in "${TEST_LIST[@]}"; do
    ((current++))
    
    echo "" | tee -a $RESULTS_LOG
    echo "═════════════════════════════════════════════════════════════════" | tee -a $RESULTS_LOG
    echo -e "${BLUE}[$current/${#TEST_LIST[@]}] Test $test_id: ${test_names[$test_id]}${NC}" | tee -a $RESULTS_LOG
    echo "═════════════════════════════════════════════════════════════════" | tee -a $RESULTS_LOG
    echo "" | tee -a $RESULTS_LOG
    
    # STEP 1: CLEANUP CLUSTER (instance-scoped when INSTANCE is set)
    echo -e "${YELLOW}🧹 Step 1/3: Cleaning cluster...${NC}" | tee -a $RESULTS_LOG
    cd $SCRIPT_DIR
    ./cleanup-operator.sh >"$RUN_DIR/cleanup-${test_id}.log" 2>&1

    if grep -q "CLEANUP COMPLETE" "$RUN_DIR/cleanup-${test_id}.log"; then
        echo "   ✅ Cluster cleaned" | tee -a $RESULTS_LOG
    else
        echo "   ⚠️  Cleanup had warnings (check $RUN_DIR/cleanup-${test_id}.log)" | tee -a $RESULTS_LOG
    fi
    
    # STEP 2: DEPLOY FRESH OPERATOR (namespace/RBAC/Deployment only - CRD was
    # installed once at suite start and is intentionally NOT re-applied here)
    echo -e "${YELLOW}📦 Step 2/3: Deploying fresh operator...${NC}" | tee -a $RESULTS_LOG
    cd $SCRIPT_DIR/..
    kubectl apply -f "$DEPLOYMENT_MANIFEST" -f "$SERVICEMONITOR_MANIFEST" >"$RUN_DIR/deploy-${test_id}.log" 2>&1
    
    # Create GitHub GitOps credentials Secret for NetworkPolicy tests (if file exists)
    CREDENTIALS_FILE="$SCRIPT_DIR/../../temp/github-gitops-credentials-secret.yaml"
    if [ -f "$CREDENTIALS_FILE" ]; then
        echo "   Creating GitHub GitOps credentials Secret..." | tee -a $RESULTS_LOG
        sed "s/namespace: permissions-binder-operator/namespace: ${NAMESPACE}/" "$CREDENTIALS_FILE" | kubectl apply -f - >>"$RUN_DIR/deploy-${test_id}.log" 2>&1 || true
    fi
    
    e2e_sleep 5
    
    # Wait for operator to be ready
    if kubectl wait --for=condition=available --timeout="$(e2e_max_wait 120)s" \
        deployment/operator-controller-manager -n "$NAMESPACE" >/dev/null 2>&1; then
        
        POD_NAME=$(kubectl get pods -n "$NAMESPACE" \
            -l control-plane=controller-manager \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        POD_STATUS=$(kubectl get pod $POD_NAME -n "$NAMESPACE" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        POD_START=$(kubectl get pod $POD_NAME -n "$NAMESPACE" \
            -o jsonpath='{.status.startTime}' 2>/dev/null)
        
        if [ "$POD_STATUS" == "Running" ]; then
            echo "   ✅ Operator ready" | tee -a $RESULTS_LOG
            echo "      Pod: $POD_NAME" | tee -a $RESULTS_LOG
            echo "      Started: $POD_START" | tee -a $RESULTS_LOG
            pod_names[$test_id]=$POD_NAME
        else
            echo -e "   ${RED}❌ ERROR: Operator pod is NOT running!${NC}" | tee -a $RESULTS_LOG
            echo "      Pod: $POD_NAME" | tee -a $RESULTS_LOG
            echo "      Status: $POD_STATUS" | tee -a $RESULTS_LOG
            kubectl describe pod $POD_NAME -n "$NAMESPACE" | grep -A 5 "Events:" >> $RESULTS_LOG
            results[$test_id]="FAIL"
            failed=$((failed + 1))
            continue
        fi
    else
        echo -e "   ${RED}❌ ERROR: Operator deployment failed (timeout)${NC}" | tee -a $RESULTS_LOG
        results[$test_id]="FAIL"
        failed=$((failed + 1))
        continue
    fi
    
    # STEP 3: RUN TEST
    echo -e "${YELLOW}▶️  Step 3/3: Running test $test_id...${NC}" | tee -a $RESULTS_LOG
    
    # Find test file
    test_file_pattern=$(get_test_file $test_id)
    if [ -z "$test_file_pattern" ]; then
        echo -e "   ${RED}❌ ERROR: Invalid test ID: $test_id${NC}" | tee -a $RESULTS_LOG
        results[$test_id]="FAIL"
        failed=$((failed + 1))
        continue
    fi
    
    test_file=$(ls $TEST_IMPL_DIR/$test_file_pattern 2>/dev/null | head -1)
    if [ -z "$test_file" ] || [ ! -f "$test_file" ]; then
        echo -e "   ${RED}❌ ERROR: Test file not found: $TEST_IMPL_DIR/$test_file_pattern${NC}" | tee -a $RESULTS_LOG
        results[$test_id]="FAIL"
        failed=$((failed + 1))
        continue
    fi
    
    # Export variables for test
    export NAMESPACE
    export TEST_RESULTS
    export SCRIPT_DIR
    export KUBECONFIG
    
    # Run test
    if bash "$test_file" >"$RUN_DIR/test-${test_id}-isolated.log" 2>&1; then
        echo "" | tee -a $RESULTS_LOG
        echo -e "${GREEN}✅ Test $test_id PASSED${NC}" | tee -a $RESULTS_LOG
        results[$test_id]="PASS"
        passed=$((passed + 1))
        
        # Show summary
        grep -E "✅ PASS|Test.*Results:" "$RUN_DIR/test-${test_id}-isolated.log" | tail -3 | tee -a $RESULTS_LOG
    else
        echo "" | tee -a $RESULTS_LOG
        echo -e "${RED}❌ Test $test_id FAILED${NC}" | tee -a $RESULTS_LOG
        results[$test_id]="FAIL"
        failed=$((failed + 1))
        
        # Show failures
        echo "   Last errors:" | tee -a $RESULTS_LOG
        grep -E "❌ FAIL|error|Error" "$RUN_DIR/test-${test_id}-isolated.log" | tail -5 | sed 's/^/   /' | tee -a $RESULTS_LOG
    fi
    
    # Show progress
    echo "" | tee -a $RESULTS_LOG
    echo -e "${BLUE}Progress: $current/${#TEST_LIST[@]} (✅ $passed passed, ❌ $failed failed)${NC}" | tee -a $RESULTS_LOG
    
    # Small pause between tests
    e2e_sleep 2
done

# FINAL SUMMARY
echo "" | tee -a $RESULTS_LOG
echo "═════════════════════════════════════════════════════════════════" | tee -a $RESULTS_LOG
echo "📊 FINAL SUMMARY" | tee -a $RESULTS_LOG
echo "═════════════════════════════════════════════════════════════════" | tee -a $RESULTS_LOG
echo "" | tee -a $RESULTS_LOG

for test_id in "${TEST_LIST[@]}"; do
    if [ "${results[$test_id]}" = "PASS" ]; then
        echo -e "✅ Test $test_id: ${test_names[$test_id]} - ${GREEN}PASSED${NC} (pod: ${pod_names[$test_id]})" | tee -a $RESULTS_LOG
    else
        echo -e "❌ Test $test_id: ${test_names[$test_id]} - ${RED}FAILED${NC}" | tee -a $RESULTS_LOG
    fi
done

total=$((passed + failed))
success_rate=$(echo "scale=1; $passed * 100 / $total" | bc 2>/dev/null || echo "N/A")

echo "" | tee -a $RESULTS_LOG
echo "═════════════════════════════════════════════════════════════════" | tee -a $RESULTS_LOG
echo "Total Tests: $total" | tee -a $RESULTS_LOG
echo -e "✅ Passed: ${GREEN}$passed${NC}" | tee -a $RESULTS_LOG
echo -e "❌ Failed: ${RED}$failed${NC}" | tee -a $RESULTS_LOG
echo "Success Rate: ${success_rate}%" | tee -a $RESULTS_LOG
echo "" | tee -a $RESULTS_LOG
echo "Results log: $RESULTS_LOG" | tee -a $RESULTS_LOG
echo "Individual logs:" | tee -a $RESULTS_LOG
echo "  - Cleanup: $RUN_DIR/cleanup-<test_id>.log" | tee -a $RESULTS_LOG
echo "  - Deploy:  $RUN_DIR/deploy-<test_id>.log" | tee -a $RESULTS_LOG
echo "  - Test:    $RUN_DIR/test-<test_id>-isolated.log" | tee -a $RESULTS_LOG
echo "" | tee -a $RESULTS_LOG
echo "Completed: $(date)" | tee -a $RESULTS_LOG
echo "═════════════════════════════════════════════════════════════════" | tee -a $RESULTS_LOG

if [ $failed -eq 0 ]; then
    echo ""
    echo -e "${GREEN}🎉 ALL TESTS PASSED!${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}⚠️  $failed test(s) failed${NC}"
    echo ""
    echo "Failed tests:"
    for test_id in "${TEST_LIST[@]}"; do
        if [ "${results[$test_id]}" = "FAIL" ]; then
            echo "  - Test $test_id: ${test_names[$test_id]}"
        fi
    done
    exit 1
fi
