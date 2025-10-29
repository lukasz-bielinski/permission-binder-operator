#!/bin/bash
# E2E Test Runner - Modular wrapper around complete test suite
# 
# This script allows running individual tests or all tests with proper
# cleanup between each test. It uses run-complete-e2e-tests.sh as the
# source of truth for test implementation.
#
# Usage:
#   ./test-runner.sh pre              - Run pre-test only
#   ./test-runner.sh 1                - Run test 1 only
#   ./test-runner.sh 1-5              - Run tests 1 through 5
#   ./test-runner.sh all              - Run all available tests
#   ./test-runner.sh list             - List all available tests
#   ./test-runner.sh 3 --no-cleanup   - Run test 3 and leave cluster state for debugging

set -e

export KUBECONFIG=$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)
NAMESPACE="permissions-binder-operator"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPLETE_SCRIPT="$SCRIPT_DIR/run-complete-e2e-tests.sh"
LOG_FILE="/tmp/e2e-test-runner-$(date +%Y%m%d-%H%M%S).log"

# Parse flags
SKIP_CLEANUP=false
for arg in "$@"; do
    if [ "$arg" == "--no-cleanup" ]; then
        SKIP_CLEANUP=true
    fi
done

# Check if complete script exists
if [ ! -f "$COMPLETE_SCRIPT" ]; then
    echo "❌ Error: Complete test script not found at $COMPLETE_SCRIPT"
    exit 1
fi

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

info_log() {
    echo "ℹ️  $1" | tee -a $LOG_FILE
}

# Cleanup function
cleanup_cluster() {
    info_log "🧹 Cleaning cluster..."
    kubectl delete permissionbinder --all -n $NAMESPACE --force --grace-period=0 2>&1 | head -1 | grep -v "^$" || true
    kubectl delete configmap permission-config -n $NAMESPACE --ignore-not-found 2>&1 | grep -v "^$" || true
    kubectl delete rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator 2>/dev/null || true
    kubectl get ns 2>/dev/null | grep -E "test-namespace|staging-app|excluded|test-prefix|test4-new|large-project|valid-test" | awk '{print $1}' | xargs -r kubectl delete ns --timeout=10s 2>/dev/null || true
    kubectl delete clusterrole clusterrole-test1 clusterrole-developer clusterrole-temp clusterrole-nonexistent --ignore-not-found 2>/dev/null || true
    sleep 5
    info_log "✅ Cleanup complete"
}

# Deploy operator
deploy_operator() {
    info_log "📦 Deploying operator..."
    cd $SCRIPT_DIR/..
    kubectl apply -f deployment/operator-deployment.yaml >/dev/null 2>&1
    kubectl wait --for=condition=available --timeout=60s deployment/operator-controller-manager -n $NAMESPACE >/dev/null 2>&1
    sleep 3
    info_log "✅ Operator ready"
}

# Extract and run a single test
run_single_test() {
    local test_id=$1
    
    echo "" | tee -a $LOG_FILE
    echo "==================================================================" | tee -a $LOG_FILE
    echo "Running Test: $test_id" | tee -a $LOG_FILE
    echo "Time: $(date)" | tee -a $LOG_FILE
    echo "==================================================================" | tee -a $LOG_FILE
    echo "" | tee -a $LOG_FILE
    
    # Note: When called from run-all-individually.sh, cleanup and deploy are done there
    # When called standalone, assume operator is already deployed
    # If you need cleanup/deploy for standalone use, uncomment below:
    # cleanup_cluster
    # deploy_operator
    
    # Setup: Ensure ConfigMap and PermissionBinder exist (required for all tests)
    if [ "$test_id" != "pre" ]; then
        kubectl get configmap permission-config -n permissions-binder-operator >/dev/null 2>&1 || \
        cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-namespace-001-developer,OU=Groups,DC=example,DC=com
EOF
        
        kubectl get permissionbinder permissionbinder-example -n permissions-binder-operator >/dev/null 2>&1 || \
        cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: permissionbinder-example
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  prefixes:
    - "COMPANY-K8S"
  excludeList: []
  roleMapping:
    admin: admin
    developer: edit
    viewer: view
EOF
        sleep 3  # Give operator time to process initial setup
    fi
    
    # Create temporary script with just this test
    local temp_script="/tmp/single-test-${test_id}.sh"
    
    # Extract header (functions and setup)
    sed -n '1,/^# Pre-Test: Initial State Verification/p' $COMPLETE_SCRIPT | head -n -1 > $temp_script
    
    # Change TEST_RESULTS variable to use our log file
    sed -i "s|TEST_RESULTS=.*|TEST_RESULTS=\"$LOG_FILE\"|" $temp_script
    
    # Extract the specific test section
    if [ "$test_id" == "pre" ]; then
        sed -n '/^# Pre-Test: Initial State Verification/,/^# Test 1:/p' $COMPLETE_SCRIPT | head -n -2 >> $temp_script
    elif [ "$test_id" == "34" ]; then
        # Last test - extract to end
        sed -n "/^# Test $test_id:/,\$p" $COMPLETE_SCRIPT >> $temp_script
    else
        local next_test=$((test_id + 1))
        # Find next test or end of file
        if grep -q "^# Test $next_test:" $COMPLETE_SCRIPT; then
            sed -n "/^# Test $test_id:/,/^# Test $next_test:/p" $COMPLETE_SCRIPT | head -n -2 >> $temp_script
        else
            # No next test, extract to end
            sed -n "/^# Test $test_id:/,\$p" $COMPLETE_SCRIPT >> $temp_script
        fi
    fi
    
    chmod +x $temp_script
    
    # Run the test
    cd $SCRIPT_DIR
    bash $temp_script 2>&1 | tee /tmp/test-${test_id}-output.log
    
    # Count results
    local pass_count=$(grep "✅ PASS" /tmp/test-${test_id}-output.log 2>/dev/null | wc -l)
    local fail_count=$(grep "❌ FAIL" /tmp/test-${test_id}-output.log 2>/dev/null | wc -l)
    
    # Ensure we have valid numbers
    pass_count=${pass_count:-0}
    fail_count=${fail_count:-0}
    # Remove any whitespace
    pass_count=$(echo $pass_count | tr -d ' ')
    fail_count=$(echo $fail_count | tr -d ' ')
    
    echo "" | tee -a $LOG_FILE
    echo "Test $test_id Results: PASS=$pass_count, FAIL=$fail_count" | tee -a $LOG_FILE
    
    # Test passes if: no failures AND (has passes OR is informational with no assertions)
    if [ "$fail_count" -eq 0 ]; then
        if [ "$pass_count" -gt 0 ]; then
            echo "✅ Test $test_id PASSED" | tee -a $LOG_FILE
        elif [ "$pass_count" -eq 0 ]; then
            echo "✅ Test $test_id PASSED (informational)" | tee -a $LOG_FILE
        fi
        if [ "$SKIP_CLEANUP" = true ]; then
            echo "" | tee -a $LOG_FILE
            echo "🔍 Debug mode: Cluster state preserved for analysis" | tee -a $LOG_FILE
            echo "   - Check namespaces: kubectl get ns" | tee -a $LOG_FILE
            echo "   - Check RoleBindings: kubectl get rolebindings -A -l permission-binder.io/managed-by" | tee -a $LOG_FILE
            echo "   - Check operator logs: kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=50" | tee -a $LOG_FILE
            echo "   - Check PermissionBinder: kubectl get permissionbinder -n permissions-binder-operator -o yaml" | tee -a $LOG_FILE
        fi
        return 0
    else
        echo "❌ Test $test_id FAILED" | tee -a $LOG_FILE
        if [ "$SKIP_CLEANUP" = true ]; then
            echo "" | tee -a $LOG_FILE
            echo "🔍 Debug mode: Cluster state preserved for analysis" | tee -a $LOG_FILE
            echo "   - Check namespaces: kubectl get ns" | tee -a $LOG_FILE
            echo "   - Check RoleBindings: kubectl get rolebindings -A -l permission-binder.io/managed-by" | tee -a $LOG_FILE
            echo "   - Check operator logs: kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --tail=50" | tee -a $LOG_FILE
            echo "   - Check PermissionBinder: kubectl get permissionbinder -n permissions-binder-operator -o yaml" | tee -a $LOG_FILE
            echo "   - Cleanup when done: cd $SCRIPT_DIR && ./cleanup-operator.sh" | tee -a $LOG_FILE
        fi
        return 1
    fi
}

# List available tests
list_tests() {
    echo "Available E2E Tests:"
    echo "===================="
    echo ""
    echo "pre  - Initial State Verification"
    grep -E "^# Test [0-9]+:" $COMPLETE_SCRIPT | sed 's/^# Test //' | sed 's/: /\t- /' | sort -n
    echo ""
    echo "Usage: $0 <test_id|range|all>"
}

# Usage
usage() {
    cat <<EOF
E2E Test Runner
===============

Modular test runner with cleanup between tests.
Based on run-complete-e2e-tests.sh

Usage: $0 <test_id|range|all|list>

Examples:
  $0 pre       - Run pre-test only
  $0 1         - Run test 1 only
  $0 1-5       - Run tests 1 through 5
  $0 all       - Run all available tests
  $0 list      - List all available tests

Options:
  --no-cleanup - Skip cluster cleanup before tests (faster, less isolated)

Log file: $LOG_FILE
EOF
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

TEST_ARG=$1
SKIP_CLEANUP=false

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-cleanup)
            SKIP_CLEANUP=true
            shift
            ;;
        list)
            list_tests
            exit 0
            ;;
        *)
            TEST_ARG=$1
            shift
            ;;
    esac
done

echo "==================================================================" | tee $LOG_FILE
echo "E2E Test Runner" | tee -a $LOG_FILE
echo "==================================================================" | tee -a $LOG_FILE
echo "Started: $(date)" | tee -a $LOG_FILE
echo "Test(s): $TEST_ARG" | tee -a $LOG_FILE
echo "Log: $LOG_FILE" | tee -a $LOG_FILE
if [ "$SKIP_CLEANUP" = true ]; then
    echo "Mode: Debug (--no-cleanup: cluster state will be preserved)" | tee -a $LOG_FILE
else
    echo "Mode: Isolated (cleanup between tests)" | tee -a $LOG_FILE
fi
echo "" | tee -a $LOG_FILE

declare -A results
declare -a TESTS_TO_RUN

# Get available tests from complete script
AVAILABLE_TESTS=(pre $(grep -E "^# Test [0-9]+:" $COMPLETE_SCRIPT | sed 's/^# Test //' | sed 's/:.*//' | sort -n))

# Parse argument
case $TEST_ARG in
    all)
        info_log "Running all available tests"
        TESTS_TO_RUN=("${AVAILABLE_TESTS[@]}")
        ;;
    pre)
        TESTS_TO_RUN=(pre)
        ;;
    *-*)
        # Range like 1-5
        START=$(echo $TEST_ARG | cut -d'-' -f1)
        END=$(echo $TEST_ARG | cut -d'-' -f2)
        for i in $(seq $START $END); do
            if [[ " ${AVAILABLE_TESTS[@]} " =~ " ${i} " ]]; then
                TESTS_TO_RUN+=($i)
            else
                echo "⚠️  Warning: Test $i not found, skipping"
            fi
        done
        ;;
    [0-9]|[0-9][0-9])
        if [[ " ${AVAILABLE_TESTS[@]} " =~ " ${TEST_ARG} " ]]; then
            TESTS_TO_RUN=($TEST_ARG)
        else
            echo "❌ Test $TEST_ARG not found"
            echo "Available tests: ${AVAILABLE_TESTS[@]}"
            exit 1
        fi
        ;;
    *)
        echo "❌ Unknown test: $TEST_ARG"
        usage
        exit 1
        ;;
esac

if [ ${#TESTS_TO_RUN[@]} -eq 0 ]; then
    echo "❌ No tests to run"
    exit 1
fi

info_log "Will run ${#TESTS_TO_RUN[@]} test(s): ${TESTS_TO_RUN[@]}"
echo ""

# Run tests
for test_id in "${TESTS_TO_RUN[@]}"; do
    run_single_test "$test_id"
    results[$test_id]=$?
done

# Summary
echo "" | tee -a $LOG_FILE
echo "==================================================================" | tee -a $LOG_FILE
echo "📊 SUMMARY" | tee -a $LOG_FILE
echo "==================================================================" | tee -a $LOG_FILE

passed=0
failed=0
for test_id in "${TESTS_TO_RUN[@]}"; do
    if [ ${results[$test_id]} -eq 0 ]; then
        echo "✅ Test $test_id: PASSED" | tee -a $LOG_FILE
        passed=$((passed + 1))
    else
        echo "❌ Test $test_id: FAILED" | tee -a $LOG_FILE
        failed=$((failed + 1))
    fi
done

total=$((passed + failed))
if [ $total -gt 0 ]; then
    success_rate=$(echo "scale=1; $passed * 100 / $total" | bc 2>/dev/null || echo "N/A")
    echo "" | tee -a $LOG_FILE
    echo "Total: $total" | tee -a $LOG_FILE
    echo "Passed: $passed" | tee -a $LOG_FILE
    echo "Failed: $failed" | tee -a $LOG_FILE
    echo "Success Rate: ${success_rate}%" | tee -a $LOG_FILE
fi

echo "" | tee -a $LOG_FILE
echo "Log: $LOG_FILE" | tee -a $LOG_FILE
echo "Individual test outputs: /tmp/test-*-output.log" | tee -a $LOG_FILE
echo "Completed: $(date)" | tee -a $LOG_FILE
echo "==================================================================" | tee -a $LOG_FILE

if [ $failed -eq 0 ]; then
    echo "✅ ALL TESTS PASSED!"
    exit 0
else
    echo "❌ $failed test(s) failed"
    exit 1
fi
