#!/bin/bash
# Run E2E tests with FULL ISOLATION
# Each test gets: fresh cluster cleanup + fresh operator deployment + test execution
# 
# Usage:
#   ./run-tests-full-isolation.sh           # Run all tests
#   ./run-tests-full-isolation.sh 3         # Run single test
#   ./run-tests-full-isolation.sh 3 7 11    # Run specific tests

set +e  # Don't exit on errors - we want to run all tests

export KUBECONFIG=$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_LOG="/tmp/e2e-full-isolation-$(date +%Y%m%d-%H%M%S).log"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get test list
if [ $# -eq 0 ]; then
    # Run all tests (pre + 1-43)
    TEST_LIST=(pre $(seq 1 43))
else
    # Run specified tests
    TEST_LIST=("$@")
fi

# Function to get test name
get_test_name() {
    local test_id=$1
    if [ "$test_id" == "pre" ]; then
        echo "Initial State Verification"
    else
        grep "^# Test ${test_id}:" $SCRIPT_DIR/run-complete-e2e-tests.sh 2>/dev/null | sed "s/^# Test ${test_id}: //" | head -1
    fi
}

echo "╔═══════════════════════════════════════════════════════════════╗" | tee $RESULTS_LOG
echo "║     🧪 E2E Tests with FULL ISOLATION                          ║" | tee -a $RESULTS_LOG
echo "╚═══════════════════════════════════════════════════════════════╝" | tee -a $RESULTS_LOG
echo "" | tee -a $RESULTS_LOG
echo "Started: $(date)" | tee -a $RESULTS_LOG
echo "Tests to run: ${#TEST_LIST[@]}" | tee -a $RESULTS_LOG
echo "Tests: ${TEST_LIST[*]}" | tee -a $RESULTS_LOG
echo "Results log: $RESULTS_LOG" | tee -a $RESULTS_LOG
echo "" | tee -a $RESULTS_LOG

declare -A results
declare -A test_names
declare -A pod_names
passed=0
failed=0
current=0

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
    
    # STEP 1: CLEANUP CLUSTER
    echo -e "${YELLOW}🧹 Step 1/3: Cleaning cluster...${NC}" | tee -a $RESULTS_LOG
    cd $SCRIPT_DIR
    ./cleanup-operator.sh >/tmp/cleanup-${test_id}.log 2>&1
    
    if grep -q "CLEANUP COMPLETE" /tmp/cleanup-${test_id}.log; then
        echo "   ✅ Cluster cleaned" | tee -a $RESULTS_LOG
    else
        echo "   ⚠️  Cleanup had warnings (check /tmp/cleanup-${test_id}.log)" | tee -a $RESULTS_LOG
    fi
    
    # STEP 2: DEPLOY FRESH OPERATOR
    echo -e "${YELLOW}📦 Step 2/3: Deploying fresh operator...${NC}" | tee -a $RESULTS_LOG
    cd $SCRIPT_DIR/..
    kubectl apply -f deployment/ >/tmp/deploy-${test_id}.log 2>&1
    sleep 5
    
    # Wait for operator to be ready
    if kubectl wait --for=condition=available --timeout=60s \
        deployment/operator-controller-manager -n permissions-binder-operator >/dev/null 2>&1; then
        
        POD_NAME=$(kubectl get pods -n permissions-binder-operator \
            -l control-plane=controller-manager \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        POD_STATUS=$(kubectl get pod $POD_NAME -n permissions-binder-operator \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        POD_START=$(kubectl get pod $POD_NAME -n permissions-binder-operator \
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
            kubectl describe pod $POD_NAME -n permissions-binder-operator | grep -A 5 "Events:" >> $RESULTS_LOG
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
    cd $SCRIPT_DIR
    
    if ./test-runner.sh $test_id >/tmp/test-${test_id}-isolated.log 2>&1; then
        echo "" | tee -a $RESULTS_LOG
        echo -e "${GREEN}✅ Test $test_id PASSED${NC}" | tee -a $RESULTS_LOG
        results[$test_id]="PASS"
        passed=$((passed + 1))
        
        # Show summary
        grep -E "✅ PASS|Test.*Results:" /tmp/test-${test_id}-isolated.log | tail -3 | tee -a $RESULTS_LOG
    else
        echo "" | tee -a $RESULTS_LOG
        echo -e "${RED}❌ Test $test_id FAILED${NC}" | tee -a $RESULTS_LOG
        results[$test_id]="FAIL"
        failed=$((failed + 1))
        
        # Show failures
        echo "   Last errors:" | tee -a $RESULTS_LOG
        grep -E "❌ FAIL|error|Error" /tmp/test-${test_id}-isolated.log | tail -5 | sed 's/^/   /' | tee -a $RESULTS_LOG
    fi
    
    # Show progress
    echo "" | tee -a $RESULTS_LOG
    echo -e "${BLUE}Progress: $current/${#TEST_LIST[@]} (✅ $passed passed, ❌ $failed failed)${NC}" | tee -a $RESULTS_LOG
    
    # Small pause between tests
    sleep 2
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
echo "  - Cleanup: /tmp/cleanup-<test_id>.log" | tee -a $RESULTS_LOG
echo "  - Deploy:  /tmp/deploy-<test_id>.log" | tee -a $RESULTS_LOG
echo "  - Test:    /tmp/test-<test_id>-isolated.log" | tee -a $RESULTS_LOG
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

