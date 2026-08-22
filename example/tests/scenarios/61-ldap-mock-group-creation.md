### Test 61: LDAP Mock Group Creation (LDAPS + custom CA)

**Objective**: End-to-end validation of `createLdapGroups` against a real (mock) LDAP server over **verified TLS** — `ldapTlsVerify: true` with a custom CA delivered via the optional `ca.crt` key of the LDAP credentials Secret (PR #39). Also proves the least-privilege Secret path from PR #24 (secrets `get`-only RBAC + informer-cache bypass) inside the regular suite.

**Setup**:
```bash
# 1. Generate CA + server certificate with openssl. SAN must cover the mock
#    Service FQDN, otherwise Go's hostname verification fails:
#      subjectAltName=DNS:openldap.<mock-ns>.svc.cluster.local,DNS:openldap.<mock-ns>.svc,DNS:openldap

# 2. Deploy the OpenLDAP mock (osixia/openldap:1.5.0) from the template
#    example/tests/ldap-mock/01-openldap.yaml (placeholders __MOCK_NS__ /
#    __CERT_SECRET__ rendered via sed). LDAPS on :636 with the generated cert
#    (Secret -> initContainer copy -> writable emptyDir at
#    /container/service/slapd/assets/certs), LDAP_TLS_VERIFY_CLIENT=never.

# 3. Load AD-compat schema (sAMAccountName + objectClass 'group', real AD
#    OIDs) via ldapadd -Y EXTERNAL -H ldapi:///, then seed
#    ou=Kubernetes,dc=example,dc=com.

# 4. Sanity check inside the pod: ldapsearch over ldaps://<FQDN>:636 with
#    LDAPTLS_CACERT=<generated CA> must succeed (proves cert + SAN).

# 5. Create the LDAP credentials Secret in the operator namespace:
#      domain_server:   ldaps://openldap.<mock-ns>.svc.cluster.local:636
#      domain_username: cn=admin,dc=example,dc=com
#      domain_password: <admin password>
#      ca.crt:          <generated CA PEM>          # the #39 contract

# 6. Create a dedicated ConfigMap (whitelist.txt with
#    CN=COMPANY-K8S-<target-ns>-developer,OU=Kubernetes,DC=example,DC=com)
#    and a PermissionBinder with createLdapGroups: true, ldapTlsVerify: true,
#    ldapSecretRef pointing at the Secret above.
```

**Execution**:
```bash
# The whitelist entry triggers reconciliation: namespace + RoleBinding are
# created, then ProcessLdapGroupCreation binds to the mock over verified
# LDAPS and creates the AD-style group entry at the full DN.
./run-tests-full-isolation.sh 61
```

**Expected Result**:
- Namespace `<target-ns>` and RoleBinding `<target-ns>-developer` exist; the RoleBinding subject is Group `COMPANY-K8S-<target-ns>-developer`.
- Operator logs (since PermissionBinder creation) contain, in order:
  - `Successfully retrieved LDAP credentials` with `"hasCaCert":true`
  - `Connected to LDAP server` with `"tlsVerify":true` and `"customCa":true`
  - `✅ Successfully created AD Group`
  - `✅ LDAP group creation completed` with `"errors":0`
- **Negative**: zero `forbidden` / `cannot list resource "secrets"` / `cannot watch resource "secrets"` / `x509:` lines — proves get-only RBAC + cache bypass (PR #24) and that TLS verification really passed against the custom CA (PR #39).
- Independent proof in LDAP: `ldapsearch` inside the mock pod finds `cn=COMPANY-K8S-<target-ns>-developer` under `ou=Kubernetes,dc=example,dc=com` with `objectClass: group` and `sAMAccountName`.
- Cleanup (trap): PermissionBinder (finalizer removes RoleBindings), ConfigMap, credentials Secret, target namespace, mock namespace, and generated certs are all removed — the mock namespace is intentionally NOT covered by the suite sweeps.

**Implementation**: [`test-61-ldap-mock-group-creation.sh`](../test-implementations/test-61-ldap-mock-group-creation.sh) — mock assets and full design notes in [`ldap-mock/README.md`](../ldap-mock/README.md).
