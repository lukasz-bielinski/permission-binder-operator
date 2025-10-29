# v1.4.0 - LDAP/AD Integration 🔐

## 🎯 Major Features

### LDAP/Active Directory Group Creation
Automatic creation of security groups in Active Directory for Kubernetes namespaces and roles.

- **CN Parsing**: Extracts group name and organizational path from LDAP DN
- **Cluster Tracking**: AD group descriptions include source cluster name and timestamp
- **Idempotent Operations**: Safely skips existing groups
- **TLS Support**: Configurable certificate verification for self-signed certs

## ✨ New CRD Fields

```yaml
spec:
  createLdapGroups: false          # Enable LDAP integration
  ldapSecretRef:                   # AD credentials
    name: ldap-credentials
    namespace: permissions-binder-operator
  ldapTlsVerify: true              # TLS certificate verification
```

## 📊 Prometheus Metrics

- `permission_binder_ldap_connections_total{status}` - Connection attempts
- `permission_binder_ldap_group_operations_total{operation}` - Group operations (created/exists/error)

## 📚 Documentation

- Comprehensive [LDAP Integration Guide](docs/LDAP_INTEGRATION.md)
- Configuration examples and troubleshooting
- Security best practices

## 🔒 Security

- Credentials stored in Kubernetes Secret
- LDAPS (TLS/SSL) support
- Configurable certificate verification
- Service account authentication

## 🧪 Testing

✅ Tested on production environment  
✅ 94% E2E test success rate (31 tests)  
✅ Multi-cluster support validated

## 🐳 Docker Images

Multi-architecture support (amd64 + arm64):
- `lukaszbielinski/permission-binder-operator:1.4.0`
- `lukaszbielinski/permission-binder-operator:1.4`
- `lukaszbielinski/permission-binder-operator:1`
- `lukaszbielinski/permission-binder-operator:latest`

## 📦 Installation

### Quick Start

```bash
kubectl apply -f https://raw.githubusercontent.com/lukasz-bielinski/permission-binder-operator/v1.4.0/example/deployment/operator-deployment.yaml
```

### With LDAP Integration

1. Create LDAP credentials Secret:
```bash
kubectl create secret generic ldap-credentials \
  -n permissions-binder-operator \
  --from-literal=domain_server='ldaps://ad.example.com:636' \
  --from-literal=domain_username='CN=svc-account,OU=...,DC=...' \
  --from-literal=domain_password='password'
```

2. Enable in PermissionBinder:
```yaml
spec:
  createLdapGroups: true
  ldapSecretRef:
    name: ldap-credentials
    namespace: permissions-binder-operator
  ldapTlsVerify: false  # For self-signed certs only
```

## 🔄 Upgrade from v1.3.0

No breaking changes - fully backward compatible!

```bash
kubectl set image deployment/operator-controller-manager \
  manager=lukaszbielinski/permission-binder-operator:1.4.0 \
  -n permissions-binder-operator
```

## ⚠️ Breaking Changes

None - fully backward compatible with v1.3.0

## 📝 Example AD Group Created

When operator creates a group in Active Directory:

**DN**: `CN=COMPANY-K8S-production-admin,OU=Production,OU=Kubernetes,DC=example,DC=com`

**Description**: 
```
Created by permission-binder-operator from cluster 'production-k8s' on 2025-01-23 14:30:00 UTC. Kubernetes namespace permission group.
```

## 🔍 Monitoring

Check LDAP operations in logs:
```bash
kubectl logs -f deployment/operator-controller-manager \
  -n permissions-binder-operator | grep -E "LDAP|AD Group"
```

Query Prometheus metrics:
```promql
# LDAP connection success rate
rate(permission_binder_ldap_connections_total{status="success"}[5m])

# Groups created vs already existing
permission_binder_ldap_group_operations_total{operation="created"}
permission_binder_ldap_group_operations_total{operation="exists"}
```

## 🐛 Bug Fixes

- Fixed YAML separator format in operator-deployment.yaml
- Corrected image tag format (1.4.0 instead of v1.4.0)

## 📊 What's Changed

* feat: Add LDAP group creation support to CRD by @lukasz-bielinski in #X
* feat: Implement LDAP/AD group creation by @lukasz-bielinski in #X
* feat: Enhanced AD group creation with cluster tracking by @lukasz-bielinski in #X
* feat: Add ldapTlsVerify option for TLS certificate verification by @lukasz-bielinski in #X
* docs: Add comprehensive LDAP integration guide by @lukasz-bielinski in #X
* chore: Update operator deployment configuration by @lukasz-bielinski in #X

**Full Changelog**: https://github.com/lukasz-bielinski/permission-binder-operator/compare/v1.3.0...v1.4.0

---

## 💬 Feedback & Support

- 📖 [Documentation](https://github.com/lukasz-bielinski/permission-binder-operator/tree/main/docs)
- 🐛 [Report Issues](https://github.com/lukasz-bielinski/permission-binder-operator/issues)
- 💡 [Feature Requests](https://github.com/lukasz-bielinski/permission-binder-operator/issues/new)


