#!/bin/bash
# Test 03: Exclude List Changes
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 3: Exclude List Changes"
echo "------------------------------"

# Cleanup: Force delete excluded-test-ns if it exists from previous test runs
kubectl_retry kubectl delete namespace excluded-test-ns --ignore-not-found --timeout=10s >/dev/null 2>&1 || true
if kubectl get namespace excluded-test-ns 2>/dev/null | grep -q Terminating; then
    kubectl delete namespace excluded-test-ns --force --grace-period=0 >/dev/null 2>&1 || true
fi
for i in {1..10}; do
    kubectl get namespace excluded-test-ns >/dev/null 2>&1 || break
    sleep 1
done

EXCLUDE_CN="COMPANY-K8S-excluded-test-ns-admin"

# Step 1: Set excludeList FIRST (before any ConfigMap with that CN)
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"replace","path":"/spec/excludeList","value":["'$EXCLUDE_CN'"]}]' >/dev/null 2>&1
sleep 2

# Step 2: Now add the excluded entry - operator should skip it (fix in v1.5.0-rc2)
cat <<EOF | kubectl_retry kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-namespace-001-developer,OU=Groups,DC=example,DC=com
    CN=${EXCLUDE_CN},OU=Test,DC=example,DC=com
EOF
sleep 5

# Verify actual cluster state: namespace should NOT exist
if kubectl_retry kubectl get namespace excluded-test-ns >/dev/null 2>&1; then
    fail_test "Namespace 'excluded-test-ns' exists despite being in excludeList"
else
    pass_test "Namespace correctly not created (excluded by excludeList)"
fi

# Verify no RoleBindings created for excluded namespace
# If namespace doesn't exist, kubectl returns "No resources found" to stderr (which we ignore)
# If namespace exists but has no RoleBindings, output is empty
# We check for managed RoleBindings specifically
EXCLUDED_NS_EXISTS=$(kubectl get namespace excluded-test-ns 2>/dev/null && echo "yes" || echo "no")
if [ "$EXCLUDED_NS_EXISTS" = "yes" ]; then
    # Namespace exists - check for RoleBindings
    EXCLUDED_RBS=$(kubectl get rolebindings -n excluded-test-ns -l permission-binder.io/managed-by --no-headers 2>/dev/null | wc -l)
    EXCLUDED_RBS=$(echo "$EXCLUDED_RBS" | tr -d ' ')
    if [ "$EXCLUDED_RBS" -eq 0 ]; then
        pass_test "Excluded namespace exists but has no managed RoleBindings (partial fail - namespace shouldn't exist)"
    else
        fail_test "Excluded namespace has $EXCLUDED_RBS managed RoleBindings (should be 0)"
    fi
else
    # Namespace doesn't exist - this is correct
    pass_test "No RoleBindings created for excluded namespace (namespace doesn't exist)"
fi

# Verify the valid namespace still works (was not affected by excludeList)
if kubectl_retry kubectl get namespace test-namespace-001 >/dev/null 2>&1; then
    pass_test "Valid namespace still exists (excludeList didn't affect valid entries)"
else
    fail_test "Valid namespace missing - excludeList may have affected it incorrectly"
fi

# Cleanup - remove excluded entry from ConfigMap FIRST, then clear excludeList
# This prevents race condition where clearing excludeList triggers creation of excluded namespace
cat <<EOF | kubectl_retry kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: $NAMESPACE
data:
  whitelist.txt: |
    CN=COMPANY-K8S-test-namespace-001-developer,OU=Groups,DC=example,DC=com
EOF
sleep 2

# Now clear excludeList
kubectl_retry kubectl patch permissionbinder permissionbinder-example -n $NAMESPACE --type=json \
  -p='[{"op":"replace","path":"/spec/excludeList","value":[]}]' >/dev/null 2>&1
sleep 1

echo ""

# ============================================================================
