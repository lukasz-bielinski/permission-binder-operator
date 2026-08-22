# LDAP mock — LDAPS server for test 61 (createLdapGroups, verified TLS)

Assets for **Test 61: LDAP Mock Group Creation (LDAPS + custom CA)**
(`../test-implementations/test-61-ldap-mock-group-creation.sh`). The mock
validates, against a real (mock) LDAP server:

1. **PR #24 Secret access path** — secrets `get`-only RBAC works because the
   operator reads Secrets via direct API GET (informer cache disabled for
   Secrets via `DisableFor` in `cmd/main.go`).
2. **PR #39 custom-CA verified TLS** — `ldapTlsVerify: true` with the CA
   provided via the optional `ca.crt` key of the LDAP credentials Secret
   (appended to the system pool in `tls.Config.RootCAs`).
3. **createLdapGroups** — `ProcessLdapGroupCreation` parses the whitelist DN,
   binds to LDAP over verified LDAPS, and creates the AD-style group entry
   (`objectClass: top,group` + `cn` + `sAMAccountName` + `description`).

## Files

| File | Purpose |
|---|---|
| `01-openldap.yaml` | Deployment+Service **template** — placeholders `__MOCK_NS__` and `__CERT_SECRET__` are rendered by the test via `sed` before apply. |
| `02-init-schema.ldif` | AD-compat schema for cn=config (`sAMAccountName` OID 1.2.840.113556.1.4.221, objectClass `group` OID 1.2.840.113556.1.5.8). |
| `02b-init-data.ldif` | `ou=Kubernetes,dc=example,dc=com` seed (parent of the group DN — the operator does NOT create parent entries). |

## Design notes (why things look the way they do)

- **Verified TLS end-to-end.** The operator runs with `ldapTlsVerify: true`,
  so the osixia auto-generated certificate (CN = container hostname) would
  fail Go's hostname verification against the Service FQDN. The test
  therefore generates its **own CA + server cert with `openssl`**, with
  `subjectAltName = DNS:openldap.<mock-ns>.svc.cluster.local,
  DNS:openldap.<mock-ns>.svc, DNS:openldap`, and hands the CA to the
  operator via the `ca.crt` Secret key (#39 contract).
- **osixia custom-cert mount convention** (osixia/openldap:1.5.0): the image
  reads certs from `/container/service/slapd/assets/certs`, filenames from
  `LDAP_TLS_CRT_FILENAME` / `LDAP_TLS_KEY_FILENAME` /
  `LDAP_TLS_CA_CRT_FILENAME`. The entrypoint's ssl-helper **chowns/chmods the
  cert files and generates `dhparam.pem` in the same directory**, so a
  read-only Secret volume mounted there breaks bootstrap. The template
  instead mounts the Secret read-only at `/tls-secret` and an
  **initContainer copies the files into a writable emptyDir** mounted at the
  assets/certs path (validated live on the k3s cluster).
- **`LDAP_TLS_VERIFY_CLIENT=never`** is required: the osixia default
  `demand` rejects TLS clients without client certificates (the operator has
  none).
- **Namespaces**: the mock lives in `${TEST_NS_PREFIX}ldap-mock` — a name
  that deliberately dodges the suite cleanup sweeps (no `test-` substring in
  legacy mode), so the test tears it down itself via `trap ... EXIT`. The
  operator-created namespace is `${TEST_NS_PREFIX}ldap-test-61` (contains
  `test-` → legacy sweep; prefixed → instance sweep).
- **CN** `CN=COMPANY-K8S-<target-ns>-developer,OU=Kubernetes,DC=example,DC=com`:
  prefix `COMPANY-K8S`, role `developer` (roleMapping key → ClusterRole
  `view`), namespace `<target-ns>`. The LDAP group is created at the FULL DN,
  so `OU=Kubernetes,DC=example,DC=com` is pre-seeded (02b).
- **`domain_server` uses the production convention** `ldaps://host:636` —
  the healthy LDAPS branch of `ConnectLdap()`. (The plain-LDAP branch has a
  latent bug: an explicit `ldap://` prefix gets mangled to
  `ldap://ldap://host:389`; not relevant here.)
- **Custom schema (02)** defines `sAMAccountName` and objectClass `group`
  with the real AD OIDs so the operator's Add succeeds on OpenLDAP.
- osixia/openldap:1.5.0 is amd64 → `nodeSelector kubernetes.io/hostname: n5pro`.
- **No persistence**: pod recreation loses schema/data — the test loads the
  LDIFs after every rollout (loads are idempotent: "Duplicate"/"Already
  exists" is tolerated).

## Manual run

The normal path is the suite (`./run-tests-full-isolation.sh 61`). To drive
the mock by hand:

```sh
export KUBECONFIG=/workspace/kubeconfig1   # or your cluster
MOCK_NS=ldap-mock
FQDN="openldap.${MOCK_NS}.svc.cluster.local"

# 1. Certs (CA + SAN server cert)
openssl genrsa -out ca.key 2048
openssl req -x509 -new -key ca.key -sha256 -days 30 -subj "/CN=ldap-mock-ca" -out ca.crt
openssl genrsa -out tls.key 2048
openssl req -new -key tls.key -subj "/CN=${FQDN}" -out server.csr
printf 'subjectAltName=DNS:%s,DNS:openldap.%s.svc,DNS:openldap\n' "$FQDN" "$MOCK_NS" > san.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 30 -sha256 -extfile san.ext -out tls.crt

# 2. Deploy
kubectl create namespace "$MOCK_NS"
kubectl create secret generic openldap-tls -n "$MOCK_NS" \
  --from-file=tls.crt --from-file=tls.key --from-file=ca.crt
sed -e "s/__MOCK_NS__/${MOCK_NS}/g" -e "s/__CERT_SECRET__/openldap-tls/g" \
  01-openldap.yaml | kubectl apply -f -
kubectl -n "$MOCK_NS" rollout status deploy/openldap --timeout=240s
sleep 10   # osixia bootstrap settles after the TCP probe

# 3. Schema + OU seed
kubectl -n "$MOCK_NS" exec -i deploy/openldap -- \
  ldapadd -Y EXTERNAL -H ldapi:/// < 02-init-schema.ldif
kubectl -n "$MOCK_NS" exec -i deploy/openldap -- \
  ldapadd -x -H ldap://localhost:389 \
    -D "cn=admin,dc=example,dc=com" -w "MockAdmin123!" < 02b-init-data.ldif

# 4. Verified-LDAPS sanity check (served cert must verify against OUR CA).
#    LDAPTLS_REQCERT=demand is mandatory — the osixia image ships
#    /etc/ldap/ldap.conf with "TLS_REQCERT never", so without the override
#    the client accepts ANY cert and the check proves nothing.
kubectl -n "$MOCK_NS" exec -i deploy/openldap -- sh -c 'cat > /tmp/ca.crt' < ca.crt
kubectl -n "$MOCK_NS" exec deploy/openldap -- sh -c \
  "LDAPTLS_REQCERT=demand LDAPTLS_CACERT=/tmp/ca.crt ldapsearch -x -H ldaps://${FQDN}:636 \
   -D 'cn=admin,dc=example,dc=com' -w 'MockAdmin123!' \
   -b 'dc=example,dc=com' -s sub '(objectClass=organizationalUnit)' dn"
# Expect: dn: ou=Kubernetes,dc=example,dc=com (and NO TLS error)
```

Operator side: credentials Secret with `domain_server: ldaps://$FQDN:636`,
`domain_username`/`domain_password` = the admin bind above, **`ca.crt`** =
the generated CA; PermissionBinder with `createLdapGroups: true`,
`ldapTlsVerify: true`, `ldapSecretRef` pointing at that Secret. See the test
script for exact manifests.

## Interpreting operator logs — pass/fail matrix

All grep strings are the exact log messages emitted by `ldap_helper.go` —
no guesswork. Restrict to the test window with
`kubectl logs ... --since-time="$T0"`.

### (a) RBAC broken — Secret GET denied ⇒ FAIL

```sh
grep -E 'Failed to get LDAP credentials Secret|secrets .*is forbidden' "$L"
grep -E 'cannot list resource "secrets"|cannot watch resource "secrets"|Failed to watch \*v1.Secret' "$L"
```

Any `is forbidden` hit on the credentials Secret GET means the get-only RBAC
+ direct-read path is broken. Any list/watch hit = the `DisableFor` cache
bypass regressed (PR #24 broken) even if the reconcile limps along.

### (b) TLS verification broken ⇒ FAIL

```sh
grep 'x509:' "$L"
# e.g. "x509: certificate signed by unknown authority"  -> ca.crt not applied
#      "x509: certificate is valid for ..."             -> SAN mismatch
grep 'failed to parse CA certificate' "$L"              # ca.crt key not PEM
```

Any hit = the #39 custom-CA path failed; the connect log below will be
absent and `Failed to connect to LDAP server` appears instead.

### (c) Full pass — all four present, in this order

```sh
grep 'Successfully retrieved LDAP credentials' "$L"   # must carry "hasCaCert":true
grep 'Connected to LDAP server' "$L"                  # must carry "tlsVerify":true,"customCa":true
grep 'Successfully created AD Group' "$L"             # LDAP Add OK
grep 'LDAP group creation completed' "$L"             # "created":1,"errors":0,"total":1
```

The `hasCaCert`/`customCa`/`tlsVerify` structured fields are the #39
contract: `hasCaCert` proves the `ca.crt` Secret key was read, `customCa`
proves it reached `tls.Config.RootCAs`, `tlsVerify` proves
`InsecureSkipVerify` was NOT used. On a re-run, `AD Group already exists
(skipping creation)` instead of "Successfully created" is also a pass
(idempotency path).

### (d) Partial pass — schema error AFTER secret read + verified bind

```sh
grep 'Failed to create LDAP group' "$L"
# LDAP result 17 "undefined attribute type" (sAMAccountName) or
# 65 "objectClassViolation" -> 02-init-schema.ldif was not loaded
```

This still proves the whole #24 + #39 chain (RBAC, cache bypass, secret
keys, verified TLS, bind) — only the AD-schema write failed. The reconcile
logs `⚠️  LDAP group creation failed (non-fatal)`; namespace/RoleBinding
creation is unaffected by design.

### Other failure signatures (environment, not RBAC/TLS)

```sh
grep 'Failed to connect to LDAP server' "$L"   # network/DNS/dial or bind fail
grep 'domain_server not found\|domain_username not found\|domain_password not found' "$L"
grep 'Failed to parse CN' "$L"                 # whitelist DN malformed
```

## Independent proof — the group exists in LDAP

```sh
kubectl -n "$MOCK_NS" exec deploy/openldap -- \
  ldapsearch -x -H ldap://localhost:389 \
    -D "cn=admin,dc=example,dc=com" -w "MockAdmin123!" \
    -b "OU=Kubernetes,DC=example,DC=com" \
    "(cn=COMPANY-K8S-<target-ns>-developer)" \
    dn objectClass cn sAMAccountName description
```

Expected: `objectClass: top` + `objectClass: group`, `cn` and
`sAMAccountName` equal to the group name, and a description of the form
`Created by permission-binder-operator from cluster '<cluster>' on
<timestamp>. Kubernetes namespace permission group.`

Optional metrics cross-check:
`permission_binder_ldap_connections_total{status="success"} >= 1` and
`permission_binder_ldap_group_operations_total{operation="created"} >= 1`
(or `"exists"` on re-run).

## Teardown

The test's `trap` handles everything (PB → finalizer removes RoleBindings;
then ConfigMap, credentials Secret, target ns, mock ns, local certs). For a
manual run: delete the same resources in that order — the mock ns is NOT
swept by the suite cleanup, delete it explicitly.
