#!/bin/bash
# Run all E2E tests individually with full separation
# Each test runs separately with cleanup, then shows results before continuing

# Don't exit on error - we want to run all tests even if some fail
set +e

export KUBECONFIG=$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/test-runner.sh"
RESULTS_LOG="/tmp/all-tests-individual-$(date +%Y%m%d-%H%M%S).log"

# Check if runner exists
if [ ! -f "$RUNNER" ]; then
    echo "❌ Error: test-runner.sh not found"
    exit 1
fi

# Get available tests
AVAILABLE_TESTS=(pre $(grep -E "^# Test [0-9]+:" $SCRIPT_DIR/run-complete-e2e-tests.sh | sed 's/^# Test //' | sed 's/:.*//' | sort -n))

# Function to get test name from source file
get_test_name() {
    local test_id=$1
    if [ "$test_id" == "pre" ]; then
        echo "Initial State Verification"
    else
        grep "^# Test ${test_id}:" $SCRIPT_DIR/run-complete-e2e-tests.sh | sed "s/^# Test ${test_id}: //" | head -1
    fi
}

echo "==================================================================" | tee $RESULTS_LOG
echo "Running All E2E Tests Individually" | tee -a $RESULTS_LOG
echo "==================================================================" | tee -a $RESULTS_LOG
echo "Started: $(date)" | tee -a $RESULTS_LOG
echo "Total tests to run: ${#AVAILABLE_TESTS[@]}" | tee -a $RESULTS_LOG
echo "Results will be saved to: $RESULTS_LOG" | tee -a $RESULTS_LOG
echo "" | tee -a $RESULTS_LOG

declare -A results
declare -A test_names
passed=0
failed=0
current=0

# Pre-load test names
for test_id in "${AVAILABLE_TESTS[@]}"; do
    test_names[$test_id]=$(get_test_name $test_id)
done

# Run each test
for test_id in "${AVAILABLE_TESTS[@]}"; do
    ((current++))
    
    echo "" | tee -a $RESULTS_LOG
    echo "==================================================================" | tee -a $RESULTS_LOG
    echo "[$current/${#AVAILABLE_TESTS[@]}] Test $test_id: ${test_names[$test_id]}" | tee -a $RESULTS_LOG
    echo "==================================================================" | tee -a $RESULTS_LOG
    echo "" | tee -a $RESULTS_LOG
    
    # 1. CLEANUP CLUSTER
    echo "🧹 Step 1: Cleaning cluster..." | tee -a $RESULTS_LOG
    cd $SCRIPT_DIR
    ./cleanup-operator.sh >/dev/null 2>&1
    echo "✅ Cleanup done" | tee -a $RESULTS_LOG
    echo "" | tee -a $RESULTS_LOG
    
    # 2. DEPLOY OPERATOR
    echo "📦 Step 2: Deploying operator..." | tee -a $RESULTS_LOG
    cd $SCRIPT_DIR/..
    kubectl apply -f deployment/ >/dev/null 2>&1
    kubectl wait --for=condition=available --timeout=60s deployment/operator-controller-manager -n permissions-binder-operator >/dev/null 2>&1
    echo "✅ Operator ready" | tee -a $RESULTS_LOG
    echo "" | tee -a $RESULTS_LOG
    
    # Run single test
    echo "▶️  Running test $test_id..." | tee -a $RESULTS_LOG
    if $RUNNER $test_id > /tmp/test-${test_id}-individual.log 2>&1; then
        echo "" | tee -a $RESULTS_LOG
        echo "✅ Test $test_id PASSED" | tee -a $RESULTS_LOG
        # Show summary
        grep -E "✅ PASS|❌ FAIL" /tmp/test-${test_id}-individual.log | head -10 | tee -a $RESULTS_LOG
        results[$test_id]="PASS"
        passed=$((passed + 1))
    else
        echo "" | tee -a $RESULTS_LOG
        echo "❌ Test $test_id FAILED" | tee -a $RESULTS_LOG
        # Show failures
        grep -E "✅ PASS|❌ FAIL" /tmp/test-${test_id}-individual.log | head -10 | tee -a $RESULTS_LOG
        results[$test_id]="FAIL"
        failed=$((failed + 1))
    fi
    
    # Show current progress
    echo "" | tee -a $RESULTS_LOG
    echo "Progress: $current/${#AVAILABLE_TESTS[@]} (Passed: $passed, Failed: $failed)" | tee -a $RESULTS_LOG
    echo "" | tee -a $RESULTS_LOG
    
    # Pause between tests
    sleep 3
done

# Final summary
echo "" | tee -a $RESULTS_LOG
echo "==================================================================" | tee -a $RESULTS_LOG
echo "📊 FINAL SUMMARY" | tee -a $RESULTS_LOG
echo "==================================================================" | tee -a $RESULTS_LOG
echo "" | tee -a $RESULTS_LOG

for test_id in "${AVAILABLE_TESTS[@]}"; do
    if [ "${results[$test_id]}" = "PASS" ]; then
        echo "✅ Test $test_id: ${test_names[$test_id]} - PASSED" | tee -a $RESULTS_LOG
    else
        echo "❌ Test $test_id: ${test_names[$test_id]} - FAILED" | tee -a $RESULTS_LOG
    fi
done

total=$((passed + failed))
success_rate=$(echo "scale=1; $passed * 100 / $total" | bc 2>/dev/null || echo "N/A")

echo "" | tee -a $RESULTS_LOG
echo "==================================================================" | tee -a $RESULTS_LOG
echo "Total Tests: $total" | tee -a $RESULTS_LOG
echo "Passed: $passed" | tee -a $RESULTS_LOG
echo "Failed: $failed" | tee -a $RESULTS_LOG
echo "Success Rate: ${success_rate}%" | tee -a $RESULTS_LOG
echo "" | tee -a $RESULTS_LOG
echo "Results log: $RESULTS_LOG" | tee -a $RESULTS_LOG
echo "Individual test logs: /tmp/test-*-individual.log" | tee -a $RESULTS_LOG
echo "Completed: $(date)" | tee -a $RESULTS_LOG
echo "==================================================================" | tee -a $RESULTS_LOG

if [ $failed -eq 0 ]; then
    echo ""
    echo "🎉 ALL TESTS PASSED!"
    exit 0
else
    echo ""
    echo "⚠️  $failed test(s) failed"
    echo ""
    echo "Failed tests:"
    for test_id in "${AVAILABLE_TESTS[@]}"; do
        if [ "${results[$test_id]}" = "FAIL" ]; then
            echo "  - Test $test_id"
        fi
    done
    exit 1
fi

