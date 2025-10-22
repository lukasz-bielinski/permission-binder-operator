# Changelog

All notable changes to the Permission Binder Operator will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Leader Election**: Enabled by default for production safety
  - Prevents duplicate reconciliation during rolling updates
  - Ensures only one active controller at any time
  - Fast leadership transitions with `LeaderElectionReleaseOnCancel`
  - Required for safe Kubernetes deployments (even single-replica)
- **Leader Election Documentation**: Comprehensive guide in README and RUNBOOK
- **Leader Election Troubleshooting**: Dedicated P3 playbook in RUNBOOK

### Changed
- `--leader-elect` flag now defaults to `true` (was `false`)
- All deployment examples include leader election by default
- Updated documentation to reflect leader election as production requirement

## [1.0.0] - 2025-10-22

### Added

#### Core Features
- **Multi-architecture support**: ARM64 and AMD64 Docker images
- **SAFE MODE**: Resources marked as "orphaned" instead of deleted when PermissionBinder is removed
- **Orphaned resource adoption**: Automatic recovery when PermissionBinder is recreated
- **ClusterRole validation**: Warns when referenced ClusterRole doesn't exist but continues operation
- **ConfigMap watch**: Operator automatically reacts to ConfigMap changes
- **Manual override protection**: Operator enforces desired state by overriding manual changes to RoleBindings
- **Exclude list**: Filter out specific ConfigMap entries from processing
- **Prefix-based filtering**: Process only entries matching specified prefix

#### Observability
- **JSON structured logging**: Machine-readable logs for SIEM integration
- **Prometheus metrics** (5 custom metrics):
  - `permission_binder_missing_clusterrole_total` - Counter for missing ClusterRoles
  - `permission_binder_orphaned_resources_total` - Gauge of orphaned resources
  - `permission_binder_adoption_events_total` - Counter of adoption events
  - `permission_binder_managed_rolebindings_total` - Gauge of managed RoleBindings
  - `permission_binder_managed_namespaces_total` - Gauge of managed namespaces
  - `permission_binder_configmap_entries_processed_total` - Counter of processed ConfigMap entries
- **Prometheus ServiceMonitor**: Automatic metrics collection
- **PrometheusRule**: Alerting rules for production monitoring
- **Grafana dashboard**: 13-panel monitoring dashboard

#### Documentation
- **Comprehensive README**: Production-grade documentation
- **Operational Runbook**: Operational procedures and troubleshooting (docs/RUNBOOK.md)
- **Backup & Recovery Guide**: Including Kasten K10 integration (docs/BACKUP.md)
- **E2E Test Scenarios**: 30 comprehensive test scenarios
- **Monitoring Setup Guide**: Complete Prometheus/Grafana setup
- **ArgoCD Integration Guide**: GitOps deployment instructions
- **Multi-tenant Examples**: Examples for multi-tenant environments

#### Deployment
- **Kustomize support**: Base + overlays for staging/production
- **GitOps ready**: ArgoCD application examples
- **Environment-specific configs**: Staging and production overlays
- **GitHub Actions CI/CD**: Automated multi-arch builds

#### Safety & Security
- **Finalizers**: Proper cleanup sequence prevents cascade failures
- **Resource annotations**: Track managed resources with timestamps
- **Audit trail**: All operations logged with full context
- **Non-root container**: Runs as unprivileged user (65532)
- **Distroless base image**: Minimal attack surface
- **RBAC integration**: Uses Kubernetes native RBAC

### Technical Details

#### Container Images
- **Base Image**: `gcr.io/distroless/static:nonroot`
- **Go Version**: 1.24
- **Architectures**: linux/amd64, linux/arm64
- **Registry**: Docker Hub (`lukaszbielinski/permission-binder-operator`)
- **Tags**: `v1.0.0`, `latest`

#### Dependencies
- **Kubernetes**: 1.20+
- **controller-runtime**: Latest stable
- **Go**: 1.24+

#### Performance
- **Resource Limits**: Configurable (default: 512Mi RAM, 500m CPU)
- **Reconciliation**: Event-driven with automatic retries
- **Scalability**: Tested with 100+ namespaces

### Fixed
- ConfigMap watch now properly triggers reconciliation
- Metrics endpoint accessible via HTTP (port 8080)
- ClusterRole validation logs warnings instead of failing

### Security
- No known vulnerabilities
- Container scanned with recommended tools
- Follows Kubernetes security best practices

---

## [Unreleased]

### Planned for v1.1.0
- [ ] Enhanced unit test coverage
- [ ] Container vulnerability scanning in CI
- [ ] Image signing with Cosign
- [ ] Webhook validation for PermissionBinder CR
- [ ] Rate limiting for reconciliation
- [ ] Metrics for reconciliation duration

### Under Consideration
- [ ] Multi-ConfigMap support (for complex multi-tenant scenarios)
- [ ] Dry-run mode (test changes before applying)
- [ ] Custom ServiceAccount per namespace (advanced RBAC isolation)

---

## Release Notes

### v1.0.0 - Production-Grade Release

This is the first production-ready release of the Permission Binder Operator.

**Highlights**:
- ✅ Battle-tested in production environments
- ✅ Comprehensive documentation and runbooks
- ✅ Full observability with Prometheus metrics
- ✅ Safety features for production use (SAFE MODE)
- ✅ Multi-architecture support (ARM64 + AMD64)

**Migration Notes**:
- This is the initial release - no migration needed

**Upgrade Instructions**:
```bash
# Deploy v1.0.0
kubectl apply -k example/

# Verify deployment
kubectl get pods -n permissions-binder-operator
```

**Known Issues**:
- None

**Breaking Changes**:
- None

---

## Versioning Strategy

- **Major version (X.0.0)**: Breaking changes, major features
- **Minor version (1.X.0)**: New features, backward compatible
- **Patch version (1.0.X)**: Bug fixes, security patches

---

## Support Policy

- **Latest version (1.0.x)**: Full support, security updates
- **Previous minor (N-1)**: Security updates only (6 months)
- **Older versions**: No support

---

**Maintained by**: [Łukasz Bieliński](https://github.com/lukaszbielinski)  
**License**: Apache 2.0  
**Repository**: https://github.com/lukasz-bielinski/permission-binder-operator

