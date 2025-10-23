# LDAP/Active Directory Integration

The Permission Binder Operator can automatically create LDAP/Active Directory groups for managed namespaces and roles.

## Overview

When `createLdapGroups` is enabled, the operator will:

1. Parse whitelist entries (full LDAP DN format)
2. Extract group name from CN and organizational path from OU/DC components
3. Connect to LDAP/AD server using provided credentials
4. Create security groups if they don't exist
5. Track operations via Prometheus metrics

## Configuration

### 1. Create LDAP Credentials Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ldap-credentials
  namespace: permissions-binder-operator
type: Opaque
stringData:
  domain_server: "ldaps://ad.example.com:636"
  domain_username: "CN=svc-k8s-operator,OU=ServiceAccounts,DC=example,DC=com"
  domain_password: "SecurePassword123!"
```

**Required Secret Keys:**
- `domain_server` - LDAP/AD server URL (supports `ldap://` and `ldaps://`)
- `domain_username` - Service account DN with group creation permissions
- `domain_password` - Service account password

### 2. Enable LDAP in PermissionBinder

```yaml
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: permissionbinder-with-ldap
  namespace: permissions-binder-operator
spec:
  roleMapping:
    engineer: edit
    admin: admin
    viewer: view
  
  prefixes:
    - "COMPANY-K8S"
  
  configMapName: "permission-config"
  configMapNamespace: "permissions-binder-operator"
  
  # Enable LDAP group creation
  createLdapGroups: true
  
  # Reference to LDAP credentials
  ldapSecretRef:
    name: "ldap-credentials"
    namespace: "permissions-binder-operator"
```

## How It Works

### DN Parsing

The operator parses LDAP Distinguished Names (DN) to extract:

**Input:**
```
CN=MT-K8S-tenant1-project1-engineer,OU=Tenant1,OU=Kubernetes,DC=example,DC=com
```

**Parsed:**
- **Group Name:** `MT-K8S-tenant1-project1-engineer`
- **Organizational Path:** `OU=Tenant1,OU=Kubernetes,DC=example,DC=com`
- **Full DN:** (used for group creation)

### Group Creation Process

1. **Validation**: Check if group already exists
2. **Creation**: If not exists, create with:
   - `objectClass`: `top`, `group`
   - `cn`: Group name from CN
   - `sAMAccountName`: Same as group name
   - `description`: Auto-generated (includes "Managed by permission-binder-operator")
3. **Idempotency**: Existing groups are skipped (logged as "exists")
4. **Race Condition Handling**: Multiple operators can safely create same group

### Example Whitelist Entry

```
# ConfigMap: permission-config
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: permissions-binder-operator
data:
  whitelist.txt: |
    # Production namespace - admin access
    CN=COMPANY-K8S-production-admin,OU=Production,OU=Kubernetes,DC=company,DC=com
    
    # Staging namespace - engineer access
    CN=COMPANY-K8S-staging-engineer,OU=Staging,OU=Kubernetes,DC=company,DC=com
```

**Result:**
- Groups created in AD at specified OU paths
- RoleBindings created in Kubernetes referencing these groups
- Users in AD groups automatically get Kubernetes permissions

## Security Considerations

### Service Account Permissions

The LDAP service account needs:
- **Read** permissions on the target OU tree
- **Create** permissions for `group` objects
- **Write** permissions for group attributes (cn, sAMAccountName, description)

### Recommended AD Setup

```powershell
# Create dedicated OU for K8s groups
New-ADOrganizationalUnit -Name "Kubernetes" -Path "DC=company,DC=com"

# Create service account
New-ADUser -Name "svc-k8s-operator" -Path "OU=ServiceAccounts,DC=company,DC=com"

# Delegate permissions
# Navigate to "Kubernetes" OU → Delegate Control → Add service account
# Grant: Create, Delete, and Manage Group Objects
```

### TLS/SSL Configuration

- **Recommended**: Use `ldaps://` (LDAP over SSL/TLS)
- **Certificate Validation**: Currently uses system CA pool
- **TODO**: Make `InsecureSkipVerify` configurable via CRD

## Monitoring

### Prometheus Metrics

The operator exposes metrics for LDAP operations:

```promql
# Total LDAP connection attempts
permission_binder_ldap_connections_total{status="success"}
permission_binder_ldap_connections_total{status="error"}

# Total LDAP group operations
permission_binder_ldap_group_operations_total{operation="created"}
permission_binder_ldap_group_operations_total{operation="exists"}
permission_binder_ldap_group_operations_total{operation="error"}
```

### Example Queries

**Group Creation Rate:**
```promql
rate(permission_binder_ldap_group_operations_total{operation="created"}[5m])
```

**LDAP Error Rate:**
```promql
sum(rate(permission_binder_ldap_connections_total{status="error"}[5m]))
```

**Groups Already Existing (Efficiency):**
```promql
permission_binder_ldap_group_operations_total{operation="exists"} / 
permission_binder_ldap_group_operations_total
```

## Logging

LDAP operations produce structured JSON logs with detailed information:

### When Group is Created

```json
{
  "level": "info",
  "message": "🔐 Starting LDAP group creation process",
  "entries": 10
}

{
  "level": "info",
  "message": "Detected cluster name",
  "cluster": "production-k8s-cluster"
}

{
  "level": "info",
  "message": "Connected to LDAP server",
  "server": "ldaps://ad.example.com:636"
}

{
  "level": "info",
  "message": "✅ Successfully created AD Group",
  "group": "COMPANY-K8S-production-admin",
  "dn": "CN=COMPANY-K8S-production-admin,OU=Production,OU=Kubernetes,DC=company,DC=com",
  "path": "OU=Production,OU=Kubernetes,DC=company,DC=com",
  "cluster": "production-k8s-cluster",
  "description": "Created by permission-binder-operator from cluster 'production-k8s-cluster' on 2025-01-15 14:30:00 UTC. Kubernetes namespace permission group."
}

{
  "level": "info",
  "message": "✅ LDAP group creation completed",
  "created": 8,
  "errors": 0,
  "total": 10,
  "cluster": "production-k8s-cluster"
}
```

### When Group Already Exists

```json
{
  "level": "info",
  "message": "ℹ️  AD Group already exists (skipping creation)",
  "group": "COMPANY-K8S-staging-engineer",
  "dn": "CN=COMPANY-K8S-staging-engineer,OU=Staging,OU=Kubernetes,DC=company,DC=com",
  "cluster": "production-k8s-cluster"
}
```

### AD Group Description Field

When a group is created, the `description` attribute in Active Directory contains:

```
Created by permission-binder-operator from cluster 'production-k8s-cluster' on 2025-01-15 14:30:00 UTC. Kubernetes namespace permission group.
```

This allows you to:
- **Audit**: Track which cluster created the group
- **Timestamp**: Know when the group was created
- **Source**: Identify groups managed by the operator vs manually created

## Cluster Name Configuration

The operator automatically detects the cluster name for AD group descriptions. It tries the following methods in order:

1. **ConfigMap `cluster-info` in `kube-system` namespace** (recommended)
2. **ConfigMap `cluster-info` in `kube-public` namespace**
3. **Fallback**: `"kubernetes-cluster"`

### Recommended: Set Cluster Name

Create a ConfigMap with your cluster name:

```bash
kubectl create configmap cluster-info \
  -n kube-system \
  --from-literal=cluster-name="production-k8s-cluster"
```

Or via YAML:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-info
  namespace: kube-system
data:
  cluster-name: "production-k8s-cluster"
```

**Why this matters:**
- AD groups will have clear descriptions showing which cluster created them
- Useful when managing multiple K8s clusters with the same AD
- Helps with auditing and troubleshooting

**Example AD Group Description:**
```
Created by permission-binder-operator from cluster 'production-k8s-cluster' on 2025-01-15 14:30:00 UTC. Kubernetes namespace permission group.
```

## Troubleshooting

### Common Issues

#### 1. Connection Errors

```
failed to connect to LDAP server: dial tcp: connection refused
```

**Solutions:**
- Verify `domain_server` URL format
- Check firewall rules (port 389 for LDAP, 636 for LDAPS)
- Ensure DNS resolution works from operator pod

#### 2. Authentication Errors

```
failed to bind to LDAP server: Invalid Credentials
```

**Solutions:**
- Verify `domain_username` DN format
- Check `domain_password` is correct
- Ensure service account is not locked/disabled

#### 3. Permission Errors

```
failed to create LDAP group: Insufficient Access Rights
```

**Solutions:**
- Verify service account has delegated permissions on target OU
- Check ACLs on the OU tree
- Use LDAP browser tool to test permissions manually

#### 4. Certificate Errors (LDAPS)

```
failed to connect: x509: certificate signed by unknown authority
```

**Solutions:**
- Add CA certificate to operator pod's trusted CA store
- Use `ldap://` (non-secure) for testing only
- TODO: Configure `InsecureSkipVerify` in CRD

### Debug Mode

Enable verbose logging:

```yaml
# In operator deployment
env:
- name: LOG_LEVEL
  value: "1"  # Verbose logging
```

## Best Practices

1. **Use Service Account**: Never use personal AD accounts
2. **Least Privilege**: Grant only necessary permissions (create groups in specific OU)
3. **Use LDAPS**: Always encrypt LDAP traffic in production
4. **Monitor Metrics**: Set up alerts for LDAP errors
5. **Test First**: Test with `createLdapGroups: false` before enabling
6. **Rotate Credentials**: Regularly rotate service account password
7. **Audit Logs**: Enable AD audit logging for group creation events

## Migration Guide

### From Manual Group Creation to Automated

1. **Inventory**: List all existing K8s-related AD groups
2. **Standardize**: Ensure groups follow naming convention
3. **Dry Run**: Deploy with `createLdapGroups: false`, verify RoleBindings
4. **Enable LDAP**: Set `createLdapGroups: true`
5. **Monitor**: Watch for "exists" vs "created" operations
6. **Validate**: Confirm no duplicate groups created

### Rollback

To disable LDAP integration:

```yaml
spec:
  createLdapGroups: false
  # ldapSecretRef can be removed or left
```

**Note**: Disabling LDAP integration does NOT delete existing AD groups. This is intentional (SAFE MODE for AD).

## Examples

See:
- [`example/permissionbinder/ldap-credentials-secret.yaml`](../example/permissionbinder/ldap-credentials-secret.yaml)
- [`example/examples/permissionbinder-with-ldap.yaml`](../example/examples/permissionbinder-with-ldap.yaml)

## Future Enhancements

- [ ] Configurable TLS verification
- [ ] Custom LDAP attributes for groups
- [ ] Group membership management (add/remove users)
- [ ] Support for nested OU creation
- [ ] LDAP connection pooling
- [ ] Dry-run mode (log only, no creation)
- [ ] Group deletion on namespace removal (opt-in)

