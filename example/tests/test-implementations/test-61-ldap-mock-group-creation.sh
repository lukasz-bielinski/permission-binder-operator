#!/bin/bash
# Test 61: LDAP Mock Group Creation (LDAPS + custom CA)
#
# End-to-end validation of createLdapGroups against a real (mock) LDAP server
# over VERIFIED TLS (ldapTlsVerify: true + custom CA from the "ca.crt" Secret
# key, PR #39). Also exercises the least-privilege Secret path from PR #24
# (secrets get-only RBAC + informer-cache bypass) inside the regular suite.
#
# The test generates its own CA + server certificate (SAN = the mock Service
# FQDN) with openssl, mounts them into osixia/openldap via a Secret, and
# asserts the operator's verified-TLS log fields (hasCaCert/tlsVerify/customCa)
# plus the group entry in LDAP itself. See example/tests/ldap-mock/README.md.

# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo ""
echo "Test 61: LDAP Mock Group Creation (LDAPS + custom CA)"
echo "------------------------------------------------------"

MOCK_DIR="$SCRIPT_DIR/ldap-mock"
MOCK_NS="${TEST_NS_PREFIX}ldap-mock"
TARGET_NS="${TEST_NS_PREFIX}ldap-test-61"
FQDN="openldap.${MOCK_NS}.svc.cluster.local"
CERT_SECRET="openldap-tls"
CERT_DIR="${RUN_DIR:-/tmp}/ldap-mock-certs-61"
BINDER_NAME="test-permissionbinder-ldapmock"
CONFIGMAP_NAME="permission-config-ldapmock"
CREDS_SECRET="ldap-mock-credentials"
LDAP_ADMIN_DN="cn=admin,dc=example,dc=com"
LDAP_ADMIN_PW="MockAdmin123!"
GROUP_CN="COMPANY-K8S-${TARGET_NS}-developer"
GROUP_DN="CN=${GROUP_CN},OU=Kubernetes,DC=example,DC=com"

cleanup_resources() {
    # PB first: the finalizer removes managed RoleBindings.
    kubectl delete permissionbinder "$BINDER_NAME" -n "$NAMESPACE" \
        --ignore-not-found=true --timeout=60s >/dev/null 2>&1
    kubectl delete configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" \
        --ignore-not-found=true >/dev/null 2>&1
    kubectl delete secret "$CREDS_SECRET" -n "$NAMESPACE" \
        --ignore-not-found=true >/dev/null 2>&1
    # The mock ns deliberately dodges the suite cleanup sweeps ("ldap-mock"
    # matches neither the legacy regex nor a test- prefix rule) — this trap is
    # its only teardown path.
    kubectl delete namespace "$TARGET_NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
    kubectl delete namespace "$MOCK_NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
    e2e_sleep 5
    rm -rf "$CERT_DIR"
}

trap cleanup_resources EXIT

# ----------------------------------------------------------------------------
# 1. Generate CA + server certificate (SAN = Service FQDN) with openssl
# ----------------------------------------------------------------------------
info_log "Generating CA + server cert for $FQDN in $CERT_DIR"
mkdir -p "$CERT_DIR"
if ! (
    set -e
    openssl genrsa -out "$CERT_DIR/ca.key" 2048 >/dev/null 2>&1
    openssl req -x509 -new -key "$CERT_DIR/ca.key" -sha256 -days 30 \
        -subj "/CN=permission-binder-e2e-ldap-mock-ca" \
        -out "$CERT_DIR/ca.crt" >/dev/null 2>&1
    openssl genrsa -out "$CERT_DIR/tls.key" 2048 >/dev/null 2>&1
    openssl req -new -key "$CERT_DIR/tls.key" -subj "/CN=${FQDN}" \
        -out "$CERT_DIR/server.csr" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s,DNS:openldap.%s.svc,DNS:openldap\n' \
        "$FQDN" "$MOCK_NS" > "$CERT_DIR/san.ext"
    openssl x509 -req -in "$CERT_DIR/server.csr" \
        -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
        -days 30 -sha256 -extfile "$CERT_DIR/san.ext" \
        -out "$CERT_DIR/tls.crt" >/dev/null 2>&1
); then
    fail_test "openssl certificate generation failed"
    exit 1
fi
pass_test "CA + server certificate generated (SAN=$FQDN)"

# ----------------------------------------------------------------------------
# 2. Deploy the mock LDAP server (ns + cert Secret + rendered template)
# ----------------------------------------------------------------------------
info_log "Deploying openldap mock into namespace $MOCK_NS"
kubectl create namespace "$MOCK_NS" --dry-run=client -o yaml | apply_yaml_with_retry
kubectl create secret generic "$CERT_SECRET" -n "$MOCK_NS" \
    --from-file=tls.crt="$CERT_DIR/tls.crt" \
    --from-file=tls.key="$CERT_DIR/tls.key" \
    --from-file=ca.crt="$CERT_DIR/ca.crt" \
    --dry-run=client -o yaml | apply_yaml_with_retry

sed -e "s/__MOCK_NS__/${MOCK_NS}/g" -e "s/__CERT_SECRET__/${CERT_SECRET}/g" \
    "$MOCK_DIR/01-openldap.yaml" | apply_yaml_with_retry

if ! kubectl rollout status -n "$MOCK_NS" deploy/openldap \
    --timeout="$(e2e_max_wait 240)s" >/dev/null 2>&1; then
    fail_test "openldap mock did not become ready in $MOCK_NS"
    exit 1
fi
# osixia needs a few seconds after the TCP probe for bootstrap (dhparam etc.)
e2e_sleep 10
pass_test "openldap mock deployed and ready in $MOCK_NS"

# ----------------------------------------------------------------------------
# 3. Load AD-compat schema + seed parent OU (idempotent: tolerate duplicates)
# ----------------------------------------------------------------------------
load_ldif_ok() {
    # $1 = ldapadd output, $2 = rc; success or already-loaded both count
    [ "$2" -eq 0 ] && return 0
    echo "$1" | grep -qiE 'Duplicate|Already exists' && return 0
    return 1
}

SCHEMA_OUT=""; SCHEMA_RC=1
for attempt in 1 2 3; do
    SCHEMA_OUT=$(kubectl exec -i -n "$MOCK_NS" deploy/openldap -- \
        ldapadd -Y EXTERNAL -H ldapi:/// < "$MOCK_DIR/02-init-schema.ldif" 2>&1)
    SCHEMA_RC=$?
    load_ldif_ok "$SCHEMA_OUT" "$SCHEMA_RC" && break
    e2e_sleep 5
done
if ! load_ldif_ok "$SCHEMA_OUT" "$SCHEMA_RC"; then
    fail_test "AD-compat schema load failed: $SCHEMA_OUT"
    exit 1
fi

DATA_OUT=$(kubectl exec -i -n "$MOCK_NS" deploy/openldap -- \
    ldapadd -x -H ldap://localhost:389 \
    -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PW" < "$MOCK_DIR/02b-init-data.ldif" 2>&1)
DATA_RC=$?
if ! load_ldif_ok "$DATA_OUT" "$DATA_RC"; then
    fail_test "OU seed load failed: $DATA_OUT"
    exit 1
fi
pass_test "AD-compat schema + ou=Kubernetes seed loaded"

# ----------------------------------------------------------------------------
# 4. Sanity: in-pod ldapsearch over ldaps:// verified against OUR CA
# ----------------------------------------------------------------------------
kubectl exec -i -n "$MOCK_NS" deploy/openldap -- sh -c 'cat > /tmp/e2e-ca.crt' \
    < "$CERT_DIR/ca.crt"

# LDAPTLS_REQCERT=demand is mandatory: the osixia image ships
# /etc/ldap/ldap.conf with "TLS_REQCERT never", so without the override the
# client would accept ANY server cert and this check would prove nothing
# (validated live: demand + our CA passes, demand + wrong CA or IP fails).
verify_ldaps() {
    kubectl exec -n "$MOCK_NS" deploy/openldap -- sh -c \
        "LDAPTLS_REQCERT=demand LDAPTLS_CACERT=/tmp/e2e-ca.crt ldapsearch -x -H ldaps://${FQDN}:636 \
         -D '${LDAP_ADMIN_DN}' -w '${LDAP_ADMIN_PW}' \
         -b 'dc=example,dc=com' -s sub '(objectClass=organizationalUnit)' dn" \
        2>/dev/null | grep -q 'ou=Kubernetes,dc=example,dc=com'
}

if wait_for_cmd 60 verify_ldaps; then
    pass_test "LDAPS sanity check: served cert verifies against generated CA for $FQDN"
else
    fail_test "LDAPS sanity check failed (cert/SAN mismatch or ou=Kubernetes missing)"
    exit 1
fi

# ----------------------------------------------------------------------------
# 5. Operator-side resources: credentials Secret (with ca.crt), ConfigMap, PB
# ----------------------------------------------------------------------------
info_log "Creating LDAP credentials Secret (ldaps://$FQDN:636 + ca.crt) in $NAMESPACE"
kubectl create secret generic "$CREDS_SECRET" -n "$NAMESPACE" \
    --from-literal=domain_server="ldaps://${FQDN}:636" \
    --from-literal=domain_username="$LDAP_ADMIN_DN" \
    --from-literal=domain_password="$LDAP_ADMIN_PW" \
    --from-file=ca.crt="$CERT_DIR/ca.crt" \
    --dry-run=client -o yaml | apply_yaml_with_retry

apply_yaml_with_retry <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIGMAP_NAME}
  namespace: ${NAMESPACE}
data:
  whitelist.txt: |-
    ${GROUP_DN}
EOF

T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
info_log "Creating PermissionBinder $BINDER_NAME (createLdapGroups=true, ldapTlsVerify=true), T0=$T0"

apply_yaml_with_retry <<EOF
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: ${BINDER_NAME}
  namespace: ${NAMESPACE}
spec:
  roleMapping:
    developer: view
  prefixes:
    - "COMPANY-K8S"
  configMapName: "${CONFIGMAP_NAME}"
  configMapNamespace: "${NAMESPACE}"
  createLdapGroups: true
  ldapSecretRef:
    name: "${CREDS_SECRET}"
    namespace: "${NAMESPACE}"
  ldapTlsVerify: true
EOF

# ----------------------------------------------------------------------------
# 6. Assertions: namespace/RoleBinding + operator log matrix + LDAP entry
# ----------------------------------------------------------------------------
op_logs() {
    kubectl logs -n "$NAMESPACE" deployment/operator-controller-manager \
        --since-time="$T0" 2>/dev/null
}
check_ns()          { kubectl get namespace "$TARGET_NS" >/dev/null 2>&1; }
check_rb()          { kubectl get rolebinding "${TARGET_NS}-developer" -n "$TARGET_NS" >/dev/null 2>&1; }
check_creds_log()   { op_logs | grep 'Successfully retrieved LDAP credentials' | grep -q '"hasCaCert":true'; }
check_connect_log() { op_logs | grep 'Connected to LDAP server' | grep '"tlsVerify":true' | grep -q '"customCa":true'; }
check_created_log() { op_logs | grep -q 'Successfully created AD Group'; }
check_summary_log() { op_logs | grep 'LDAP group creation completed' | grep -q '"errors":0'; }

if wait_for_cmd 120 check_ns; then
    pass_test "Namespace $TARGET_NS created from whitelist"
else
    fail_test "Namespace $TARGET_NS not created within timeout"
    exit 1
fi

if wait_for_cmd 60 check_rb; then
    RB_SUBJECT=$(kubectl get rolebinding "${TARGET_NS}-developer" -n "$TARGET_NS" \
        -o jsonpath='{.subjects[0].kind} {.subjects[0].name}' 2>/dev/null)
    if [ "$RB_SUBJECT" = "Group ${GROUP_CN}" ]; then
        pass_test "RoleBinding ${TARGET_NS}-developer bound to Group ${GROUP_CN}"
    else
        fail_test "RoleBinding subject mismatch: got '$RB_SUBJECT', want 'Group ${GROUP_CN}'"
    fi
else
    fail_test "RoleBinding ${TARGET_NS}-developer not created within timeout"
fi

if wait_for_cmd 120 check_creds_log; then
    pass_test "Operator log: 'Successfully retrieved LDAP credentials' with \"hasCaCert\":true"
else
    fail_test "Operator log missing 'Successfully retrieved LDAP credentials' with \"hasCaCert\":true"
fi

if wait_for_cmd 60 check_connect_log; then
    pass_test "Operator log: 'Connected to LDAP server' with \"tlsVerify\":true and \"customCa\":true"
else
    fail_test "Operator log missing 'Connected to LDAP server' with \"tlsVerify\":true + \"customCa\":true"
fi

if wait_for_cmd 60 check_created_log; then
    pass_test "Operator log: 'Successfully created AD Group'"
else
    fail_test "Operator log missing 'Successfully created AD Group'"
fi

if wait_for_cmd 60 check_summary_log; then
    pass_test "Operator log: 'LDAP group creation completed' with \"errors\":0"
else
    fail_test "Operator log missing 'LDAP group creation completed' with \"errors\":0"
fi

# Negative assertions: no RBAC denials (PR #24 get-only path intact) and no
# TLS verification failures (PR #39 custom-CA path actually verified).
NEG_LINES=$(op_logs | grep -E 'forbidden|cannot list resource "secrets"|cannot watch resource "secrets"|x509:' || true)
if [ -z "$NEG_LINES" ]; then
    pass_test "No 'forbidden'/'cannot list|watch secrets'/'x509:' lines since T0"
else
    fail_test "Forbidden/x509 lines found in operator logs: $(echo "$NEG_LINES" | head -3)"
fi

# Independent proof: the group entry exists in LDAP with AD attributes.
check_group_in_ldap() {
    kubectl exec -n "$MOCK_NS" deploy/openldap -- \
        ldapsearch -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PW" \
        -b "OU=Kubernetes,DC=example,DC=com" "(cn=${GROUP_CN})" \
        dn objectClass cn sAMAccountName 2>/dev/null \
        | grep -q "objectClass: group"
}

if wait_for_cmd 60 check_group_in_ldap; then
    LDAP_ENTRY=$(kubectl exec -n "$MOCK_NS" deploy/openldap -- \
        ldapsearch -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PW" \
        -b "OU=Kubernetes,DC=example,DC=com" "(cn=${GROUP_CN})" \
        dn objectClass cn sAMAccountName 2>/dev/null)
    if echo "$LDAP_ENTRY" | grep -qi "sAMAccountName: ${GROUP_CN}"; then
        pass_test "LDAP entry cn=${GROUP_CN} exists with objectClass=group + sAMAccountName"
    else
        fail_test "LDAP entry cn=${GROUP_CN} exists but sAMAccountName is missing"
    fi
else
    fail_test "LDAP entry cn=${GROUP_CN} not found under ou=Kubernetes"
fi

echo ""
