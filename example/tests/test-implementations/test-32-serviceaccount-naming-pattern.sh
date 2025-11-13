#!/bin/bash
# Test 32: Serviceaccount Naming Pattern
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 32: ServiceAccount Naming Pattern"
echo "----------------------------------------"

# Create PermissionBinder with custom pattern
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: test-sa-pattern
  namespace: $NAMESPACE
spec:
  configMapName: permission-config
  configMapNamespace: $NAMESPACE
  prefixes:
    - "COMPANY-K8S"
  roleMapping:
    developer: edit
  serviceAccountMapping:
    deploy: edit
  serviceAccountNamingPattern: "sa-{namespace}-{name}"
EOF

sleep 10

# Check custom naming pattern
if kubectl get namespace test-namespace-001 >/dev/null 2>&1; then
    if kubectl get sa sa-test-namespace-001-deploy -n test-namespace-001 >/dev/null 2>&1; then
        pass_test "Custom naming pattern works (sa-{namespace}-{name})"
    else
        fail_test "Custom naming pattern not applied"
    fi
else
    info_log "test-namespace-001 does not exist, skipping pattern test"
fi

echo ""

# ============================================================================
