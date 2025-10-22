#!/bin/bash
# Test concurrent modifications to ConfigMap and PermissionBinder
# This tests race conditions and eventual consistency

export KUBECONFIG=$(readlink -f ~/workspace01/k3s-cluster/kubeconfig1)

echo "=== Starting Concurrent Modification Test ==="
echo "This test simulates rapid changes to both ConfigMap and PermissionBinder"
echo ""

# Capture initial state
INITIAL_RB=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
echo "Initial RoleBindings: $INITIAL_RB"
echo ""

# Start background job: rapid ConfigMap changes
echo "Starting rapid ConfigMap changes in background..."
(
  for i in {1..5}; do
    kubectl patch configmap permission-config -n permissions-binder-operator \
      --type=merge -p "{\"data\":{\"NEW_PREFIX-concurrent-test-$i-admin\":\"NEW_PREFIX-concurrent-test-$i-admin\"}}"
    sleep 0.5
  done
) &
CM_PID=$!

# Simultaneously: rapid PermissionBinder changes
echo "Starting rapid PermissionBinder changes..."
sleep 0.2
for i in {1..3}; do
  kubectl annotate permissionbinder permissionbinder-example -n permissions-binder-operator \
    test-trigger-$i="$(date +%s)" --overwrite
  sleep 0.7
done

# Wait for background ConfigMap changes
wait $CM_PID

echo ""
echo "Waiting for operator to reconcile (30 seconds)..."
sleep 30

# Check final state
FINAL_RB=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator --no-headers | wc -l)
echo "Final RoleBindings: $FINAL_RB"
echo "Difference: $(($FINAL_RB - $INITIAL_RB))"
echo ""

# Check for duplicates
echo "Checking for duplicate RoleBindings..."
DUPLICATES=$(kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator \
  -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' | sort | uniq -d)

if [ -z "$DUPLICATES" ]; then
  echo "✅ No duplicates found"
else
  echo "❌ DUPLICATES FOUND:"
  echo "$DUPLICATES"
fi
echo ""

# Check operator logs for errors
echo "Checking operator logs for errors during concurrent test..."
ERRORS=$(kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --since=2m \
  | jq -c 'select(.level=="error")' | wc -l)
echo "Errors in last 2 minutes: $ERRORS"

if [ "$ERRORS" -eq 0 ]; then
  echo "✅ No errors during concurrent modifications"
else
  echo "Errors found:"
  kubectl logs -n permissions-binder-operator deployment/operator-controller-manager --since=2m \
    | jq 'select(.level=="error") | {timestamp, message, error}'
fi
echo ""

# Check final consistency
echo "Verifying eventual consistency..."
kubectl get permissionbinder permissionbinder-example -n permissions-binder-operator \
  -o jsonpath='{.status.conditions[0].message}'
echo ""
echo ""

echo "=== Test Complete ==="
echo "Expected: No duplicates, no critical errors, eventual consistency achieved"



