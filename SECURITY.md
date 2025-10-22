# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in the Permission Binder Operator, please report it responsibly.

### How to Report

1. Open a GitHub issue with the label `security`
2. Provide details:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if available)
3. For sensitive issues, you can also use [GitHub Security Advisories](https://github.com/lukasz-bielinski/permission-binder-operator/security/advisories/new)

### What to Expect

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 7 days
- **Fix Timeline**: Depends on severity
  - Critical: 7 days
  - High: 14 days
  - Medium: 30 days
  - Low: 90 days

## Supported Versions

| Version | Supported          | Security Updates |
| ------- | ------------------ | ---------------- |
| 1.0.x   | :white_check_mark: | Yes              |
| < 1.0   | :x:                | No               |

## Security Features

### Built-in Security

- **RBAC Integration**: Uses Kubernetes native RBAC
- **ClusterRole Validation**: Warns about non-existent ClusterRoles
- **Audit Logging**: JSON structured logs for SIEM integration
- **SAFE MODE**: Prevents cascade deletions
- **Minimal Privileges**: Operator runs with least required permissions

### Container Security

- **Distroless Base Image**: Minimal attack surface
- **Non-root User**: Runs as unprivileged user (65532)
- **Multi-arch Support**: ARM64 and AMD64
- **No Shell Access**: Distroless images have no shell

### Kubernetes Security

- **ServiceAccount**: Dedicated service account with specific RBAC
- **NetworkPolicies**: Can be applied (not included by default)
- **PodSecurityPolicy**: Compatible with PSP/PSA
- **Resource Limits**: Configurable CPU/memory limits

## Security Best Practices

### Deployment

1. **Use specific image tags** in production (not `latest`)
2. **Enable Pod Security Standards** (restricted mode)
3. **Apply NetworkPolicies** to limit operator communication
4. **Configure resource limits** to prevent resource exhaustion
5. **Enable audit logging** in Kubernetes API server

### Monitoring

1. **Watch for security alerts** in operator logs:
   ```bash
   kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | \
     jq 'select(.level=="warning" or .level=="error")'
   ```

2. **Monitor Prometheus metrics** for anomalies:
   - `permission_binder_missing_clusterrole_total`
   - `permission_binder_orphaned_resources_total`

3. **Set up alerts** for suspicious activity

### ConfigMap Security

The operator processes ConfigMap data to create RoleBindings. Ensure:

1. **Restrict ConfigMap access** using RBAC
2. **Validate entries** before adding to ConfigMap
3. **Use exclude lists** for sensitive namespaces
4. **Audit ConfigMap changes** via Kubernetes audit logs

## Known Limitations

### By Design

1. **Operator Permissions**: Operator requires cluster-admin or equivalent permissions to create RoleBindings across all namespaces
2. **ConfigMap Trust**: Operator trusts ConfigMap content - ensure proper RBAC on ConfigMap
3. **ClusterRole Creation**: Operator does NOT create ClusterRoles, only references them

### Mitigations

1. **SAFE MODE**: Resources are marked as orphaned, not deleted
2. **Validation**: ClusterRole existence is validated with warnings
3. **Audit Trail**: All actions logged in JSON format

## Security Updates

Security updates are released as:
- **Patch versions**: For security fixes (e.g., 1.0.1)
- **Announced via**: GitHub Security Advisories
- **Documented in**: CHANGELOG.md

Subscribe to repository notifications to receive security updates.

## Vulnerability Disclosure Timeline

1. **Day 0**: Vulnerability reported
2. **Day 1-2**: Acknowledgment sent
3. **Day 3-7**: Assessment and fix development
4. **Day 7-30**: Fix released (depending on severity)
5. **Day 30+**: Public disclosure (if coordinated)

## Security Checklist for Deployment

Before deploying to production:

- [ ] Use specific image version (not `latest`)
- [ ] Review and restrict operator RBAC permissions
- [ ] Configure resource limits
- [ ] Enable JSON audit logging
- [ ] Set up Prometheus monitoring
- [ ] Configure alerts for security metrics
- [ ] Review ConfigMap access controls
- [ ] Enable Pod Security Standards
- [ ] Apply NetworkPolicies (optional)
- [ ] Document incident response procedures

## Contact

For security-related questions (non-vulnerability):
- Open a GitHub Discussion
- Use the `security` label

## Attribution

We appreciate the work of security researchers and will acknowledge contributors in:
- CHANGELOG.md
- GitHub Security Advisories
- Release notes (if appropriate)

---

**Last Updated**: October 22, 2025  
**Next Review**: v1.1.0 release

