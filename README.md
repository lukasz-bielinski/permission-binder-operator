# Permission Binder Operator

**Production-Grade Kubernetes Operator for Enterprise Environments**

A safe, predictable, and auditable Kubernetes operator that automatically manages RBAC RoleBindings based on ConfigMap entries.

[![Docker Hub](https://img.shields.io/badge/Docker%20Hub-v1.6.0-blue?logo=docker)](https://hub.docker.com/r/lukaszbielinski/permission-binder-operator)
[![GitHub Release](https://img.shields.io/badge/Release-v1.6.0-green?logo=github)](https://github.com/lukasz-bielinski/permission-binder-operator/releases/tag/v1.6.0)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

---

## 🚀 What's New in v1.6.0

### 🔒 **SECURITY CRITICAL: Token Leak Prevention**
- ✅ Binary `git-askpass-helper` prevents credentials in logs/process args
- ✅ Banking/SOC2/GDPR compliant credential handling
- ✅ Zero tokens in: `ps aux`, operator logs, error messages

### 🐛 **Bug Fixes**
- ✅ Race condition in status updates fixed (retry logic with backoff)
- ✅ Zero `"object has been modified"` errors

### ✨ **Features**
- ✅ **NetworkPolicy GitOps Management**: Automated PR creation, drift detection, auto-merge
- ✅ **17 New E2E Tests**: Comprehensive NetworkPolicy testing (Tests 44-60)
- ✅ **61 Total E2E Scenarios**: All passing ✅

📖 **Full Release Notes**: [v1.6.0 Release](https://github.com/lukasz-bielinski/permission-binder-operator/releases/tag/v1.6.0)

---

## 🏢 Production-Grade Features

### Security
- ✅ **ClusterRole Validation** - Warns when ClusterRole doesn't exist (security critical)
- ✅ **SAFE MODE** - Never deletes namespaces or RoleBindings accidentally
- ✅ **Finalizer Protection** - Proper cleanup sequence prevents cascade failures
- ✅ **Override Protection** - Enforces desired state (prevents manual tampering)
- ✅ **Audit Trail** - All operations logged in JSON for SIEM integration
- ✅ **Image Signing** - Cosign signatures + GitHub Attestations (SLSA provenance)

### Reliability
- ✅ **Orphaned Resource Adoption** - Automatic recovery with zero data loss
- ✅ **Graceful Error Handling** - Partial failures don't cascade
- ✅ **Automatic Reconciliation** - Self-healing on configuration changes
- ✅ **Finalizer-based Cleanup** - Ensures proper resource lifecycle
- ✅ **Leader Election** - Safe rolling updates with zero downtime

### Observability
- ✅ **JSON Structured Logging** - Machine-readable logs for SIEM
- ✅ **Prometheus Metrics** - 6 custom metrics for monitoring
- ✅ **Grafana Dashboard** - Pre-built 13-panel dashboard
- ✅ **AlertManager Rules** - Loki and Prometheus alerts

---

## Quick Start

### Prerequisites
- Kubernetes 1.19+
- Existing ClusterRoles for mapping

### Installation

```bash
# Deploy operator
kubectl apply -k example/

# Verify operator is running
kubectl get pods -n permissions-binder-operator

# Check logs (JSON formatted)
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | jq '.'
```

### Basic Configuration

```yaml
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: permissionbinder-example
  namespace: permissions-binder-operator
spec:
  roleMapping:
    engineer: edit
    admin: admin
    viewer: view
    read-only: view
  prefixes:
    - "COMPANY-K8S"
  excludeList:
    - "COMPANY-K8S-SYSTEM-admin"
  configMapName: "permission-config"
  configMapNamespace: "permissions-binder-operator"
  # Optional: Automatic ServiceAccount creation for CI/CD
  serviceAccountMapping:
    deploy: edit      # For CI/CD pipelines
    runtime: view     # For application pods
  serviceAccountNamingPattern: "{namespace}-sa-{name}"  # Default pattern
```

**Multi-Prefix Support** (for multi-tenant environments):
```yaml
spec:
  prefixes:
    - "MT-K8S-DEV"  # Longest prefix matched first
    - "COMPANY-K8S"
    - "MT-K8S"
  roleMapping:
    engineer: edit
    admin: admin
```

---

## Architecture

### How It Works

1. **ConfigMap Monitoring** - Operator watches ConfigMap for changes
2. **LDAP DN Parsing** - Extracts CN value from LDAP Distinguished Name format
3. **Permission String Parsing** - Extracts namespace and role from CN (format: `{PREFIX}-{NAMESPACE}-{ROLE}`)
4. **Validation** - Checks ClusterRole exists (logs WARNING if not)
5. **Namespace Creation** - Creates namespace if doesn't exist (with annotations)
6. **RoleBinding Creation** - Creates RoleBinding linking LDAP group DN to ClusterRole
7. **ServiceAccount Management** - Optionally creates ServiceAccounts for CI/CD and runtime pods with RoleBindings
8. **LDAP Group Creation** - Optionally creates LDAP/AD groups automatically (see [LDAP Integration](docs/LDAP_INTEGRATION.md))
9. **NetworkPolicy GitOps** - Automated NetworkPolicy management via GitHub Pull Requests (template-based, drift detection, auto-merge)
10. **Reconciliation** - Continuously ensures desired state

### ConfigMap Format

The operator expects a `whitelist.txt` key in the ConfigMap containing LDAP Distinguished Name (DN) entries:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: default
data:
  whitelist.txt: |-
    CN=COMPANY-K8S-project1-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-project2-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-project3-viewer,OU=Kubernetes,OU=Platform,DC=example,DC=com
```

**Format Details:**
- Each line must be a valid LDAP DN starting with `CN=`
- The CN value is extracted and parsed as `{PREFIX}-{NAMESPACE}-{ROLE}`
- Empty lines and lines starting with `#` are ignored (comments)
- The CN value (not full DN) is used as the group name in RoleBinding
- Compatible with OpenShift LDAP sync (which creates groups with CN as name)

**Example Parsing:**
```
Input LDAP DN: CN=COMPANY-K8S-project1-engineer,OU=Kubernetes,...
Extracted CN:  COMPANY-K8S-project1-engineer
Prefix:        COMPANY-K8S (from PermissionBinder spec.prefixes)
Namespace:     project1 (everything between prefix and role)
Role:          engineer (matched from spec.roleMapping keys)
Group Name:    COMPANY-K8S-project1-engineer (CN value used in RoleBinding)

Input LDAP DN: CN=MT-K8S-tenant1-project-3121-engineer,OU=...
Extracted CN:  MT-K8S-tenant1-project-3121-engineer
Prefix:        MT-K8S (from spec.prefixes)
Namespace:     tenant1-project-3121 (supports hyphens!)
Role:          engineer
Group Name:    MT-K8S-tenant1-project-3121-engineer

Input LDAP DN: CN=MT-K8S-DEV-app-staging-admin,OU=...
Prefixes:      ["MT-K8S-DEV", "MT-K8S"]
Matched:       MT-K8S-DEV (longest prefix first)
Namespace:     app-staging
Role:          admin
Group Name:    MT-K8S-DEV-app-staging-admin
```

**RoleBinding Example:**
```yaml
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: COMPANY-K8S-project1-engineer  # CN value, not full LDAP DN
```

**Important Notes:**
- **Multiple Prefixes**: Supports multiple prefixes (e.g., for different tenants)
- **Prefix Matching**: Longest prefix is matched first (handles overlapping like "MT-K8S-DEV" and "MT-K8S")
- **Role Identification**: Role is matched against `roleMapping` keys from PermissionBinder CR
- **Namespace Hyphens**: Namespaces can contain hyphens (e.g., `project-123`, `tenant1-app-staging`)
- **Role Disambiguation**: If multiple roles match, the longest role name is preferred (e.g., `read-only` over `only`)
- **Suffix Matching**: Role matching is suffix-based - the CN must end with `-{role}`

### Key Behaviors

- **Prefix Change** → Removes old RoleBindings, creates new ones
- **Role Removed from Mapping** → Deletes all RoleBindings for that role
- **Manual Edit** → Operator overrides back to desired state
- **PermissionBinder Deleted** → Resources marked as "orphaned" (NOT deleted - SAFE MODE)
- **PermissionBinder Recreated** → Automatically adopts orphaned resources

---

## Documentation

### For Operations
- [**Runbook**](docs/RUNBOOK.md) - Operational procedures and troubleshooting
- [**Backup & Recovery**](docs/BACKUP.md) - DR procedures with Kasten K10
- [E2E Test Scenarios](example/tests/scenarios/) - 61 comprehensive test scenarios (Pre + Tests 1-60)
- [Monitoring Guide](example/monitoring/README.md) - Metrics, alerts, dashboards

### For Features
- [**ServiceAccount Management**](docs/SERVICE_ACCOUNT_MANAGEMENT.md) - Automated ServiceAccount creation for CI/CD
- [**LDAP Integration**](docs/LDAP_INTEGRATION.md) - Automatic LDAP/AD group creation
- [**NetworkPolicy GitOps**](example/tests/NETWORKPOLICY_TESTING.md) - Automated NetworkPolicy management via GitHub

### For Deployment
- [GitOps Deployment](example/README.md) - ArgoCD integration
- [Multi-Arch Build](operator/README.md) - Building for ARM64 & AMD64

---

## Monitoring

### Prometheus Metrics

```bash
# Access metrics endpoint
kubectl port-forward -n permissions-binder-operator deployment/operator-controller-manager 8443:8443
curl -k https://localhost:8443/metrics | grep permission_binder
```

**Custom Metrics:**
- `permission_binder_missing_clusterrole_total` - Missing ClusterRoles (security!)
- `permission_binder_orphaned_resources_total` - Orphaned resources count
- `permission_binder_adoption_events_total` - Successful adoptions
- `permission_binder_managed_rolebindings_total` - Managed RoleBindings
- `permission_binder_managed_namespaces_total` - Managed Namespaces
- `permission_binder_configmap_entries_processed_total` - Processing status

### JSON Logs

```bash
# All errors
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq 'select(.level=="error")'

# Security warnings
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq 'select(.severity=="warning")'

# Missing ClusterRoles
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq 'select(.clusterRole and .severity=="warning")'
```

### Alerts

- **Loki Alerts** - Log-based alerting (instant, rich context)
- **Prometheus Alerts** - Metrics-based alerting (low overhead, aggregated)
- See [`example/monitoring/`](example/monitoring/) for configurations

---

## Safety Features

### SAFE MODE

When PermissionBinder is deleted:
- ✅ RoleBindings are **NOT deleted** (marked as orphaned)
- ✅ Namespaces are **NOT deleted** (marked as orphaned)
- ✅ Resources get `orphaned-at` and `orphaned-by` annotations
- ✅ Automatic adoption when PermissionBinder is recreated

**Why?** Prevents cascade failures and accidental data loss in production.

### ClusterRole Validation

Before creating RoleBinding:
- ✅ Checks if ClusterRole exists
- ✅ Logs WARNING if missing (with `security_impact: high`)
- ✅ Creates RoleBinding anyway (will work when ClusterRole is created)
- ✅ Increments Prometheus metric for alerting

### Override Protection

- ✅ Manual changes to RoleBindings are **automatically reverted**
- ✅ Ensures predictability and consistency
- ✅ Prevents configuration drift

---

## Development

### Building

```bash
# Multi-arch build (ARM64 + AMD64)
cd operator
make multi-arch-build IMG=lukaszbielinski/permission-binder-operator:latest

# Single arch (AMD64 only)
make docker-build IMG=lukaszbielinski/permission-binder-operator:latest

# Static binaries
make build-static
```

### Testing

**Comprehensive E2E Test Suite - 61 Tests** ✅

```bash
cd example/tests

# Run tests with full isolation (fresh operator deployment per test) - RECOMMENDED
./run-tests-full-isolation.sh              # All tests (pre + 1-60)
./run-tests-full-isolation.sh 44 45 46     # Specific tests (e.g., NetworkPolicy)

# Run unit tests
cd ../../operator
make test
```

**Test Categories:**
- **Basic Functionality (1-11)**: Role mapping, prefixes, ConfigMap handling
- **Security & Reliability (12-24)**: Security validation, error handling, observability
- **Metrics & Monitoring (25-30)**: Prometheus metrics, metrics updates
- **ServiceAccount Management (31-41)**: Creation, protection, updates
- **Bug Fixes (42-43)**: Regression tests for fixed bugs
- **NetworkPolicy Management (44-60)**: GitOps-based NetworkPolicy management (17 tests)

See [NetworkPolicy Testing Guide](example/tests/NETWORKPOLICY_TESTING.md) for details.

See detailed scenarios: [example/e2e-test-scenarios.md](example/e2e-test-scenarios.md)

**Adding New Tests**: See [example/tests/ADDING_NEW_TESTS.md](example/tests/ADDING_NEW_TESTS.md)

---

## Image Security & Supply Chain

All Docker images are **cryptographically signed** and include **supply chain attestations** for maximum security:

### 🔐 Security Features
- ✅ **Cosign Signatures** - All images signed with Sigstore Cosign (keyless signing)
- ✅ **GitHub Attestations** - SLSA provenance for complete build verification
- ✅ **Multi-Architecture** - AMD64 and ARM64 builds, both signed
- ✅ **Automated Signing** - GitHub Actions automatically signs every release

### 🔍 Verify Image Authenticity

**Using Cosign (recommended):**
```bash
# Verify image signature
cosign verify \
  --certificate-identity-regexp="https://github.com/lukasz-bielinski/permission-binder-operator" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  lukaszbielinski/permission-binder-operator:1.5.7
```

**Using GitHub CLI (for attestations):**
```bash
# Verify GitHub Attestations
gh attestation verify \
  oci://lukaszbielinski/permission-binder-operator:1.5.0 \
  --owner lukasz-bielinski
```

**Check SLSA Build Provenance:**
```bash
# Verify supply chain provenance
cosign verify-attestation \
  --certificate-identity-regexp="https://github.com/lukasz-bielinski/permission-binder-operator" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --type slsaprovenance \
  lukaszbielinski/permission-binder-operator:1.5.7 | jq .
```

### 📋 What's Verified?
- **Builder Identity** - Confirms image was built by GitHub Actions
- **Source Repository** - Verifies image comes from this repository
- **Build Integrity** - Ensures no tampering after build
- **Dependency Chain** - SLSA provenance tracks all build inputs

---

## Production Deployment

### Requirements
- Single replica (HA-ready with leader election enabled)
- Namespace: `permissions-binder-operator`
- RBAC: `cluster-admin` (operator manages cluster-wide RBAC)
- Memory: 128Mi-512Mi
- CPU: 100m-500m

### GitOps (ArgoCD)

```bash
# Deploy via ArgoCD
kubectl apply -f example/argocd-application.yaml

# Or manually
kubectl apply -k example/
```

### Monitoring Setup

```bash
# Deploy alerts
kubectl apply -f example/monitoring/prometheus-alerts.yaml
kubectl apply -f example/monitoring/loki-alerts.yaml

# Import Grafana dashboard
# Use example/monitoring/grafana-dashboard.json
```

---

## Key Concepts

### Annotations

All managed resources have annotations:
- `permission-binder.io/managed-by: permission-binder-operator`
- `permission-binder.io/created-at: 2025-10-15T12:00:00Z`
- `permission-binder.io/permission-binder: permissionbinder-example`
- `permission-binder.io/orphaned-at: ...` (when orphaned)
- `permission-binder.io/orphaned-by: permission-binder-deletion` (why orphaned)

### Finalizer

`permission-binder.io/finalizer` ensures:
- Cleanup logic runs before PermissionBinder deletion
- Resources are properly marked as orphaned
- No stuck deletions

### Leader Election

Leader election is **enabled by default** for production safety:
- Prevents duplicate reconciliation during rolling updates
- Ensures only one active controller at any time
- Required for safe Kubernetes deployments (even single-replica)

**How it works:**
1. During rolling update, both old and new pods exist briefly
2. Leader election ensures only ONE pod is active
3. Old leader releases lock on shutdown (< 1 second)
4. New leader takes over immediately
5. Zero downtime, zero duplicate operations

**Configuration:**
```bash
# Leader election is enabled by default
# To disable (NOT recommended for production):
--leader-elect=false
```

**Leader Election Metrics:**
```promql
# Check current leader
leader_election_master_status{name="permission-binder-operator"}

# Leader transitions during rolling updates
rate(leader_election_master_status[5m])
```

---

## Troubleshooting

### Users Can't Access Resources

```bash
# 1. Check RoleBinding exists
kubectl get rolebindings -n <namespace> -l permission-binder.io/managed-by=permission-binder-operator

# 2. Check for ClusterRole warning
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq 'select(.severity=="warning" and .namespace=="<namespace>")'

# 3. Verify ClusterRole exists
kubectl get clusterrole <clusterrole-name>
```

### Orphaned Resources

```bash
# List orphaned resources
kubectl get rolebindings -A -o json \
  | jq '.items[] | select(.metadata.annotations["permission-binder.io/orphaned-at"])'

# Adopt them - recreate PermissionBinder
kubectl apply -f permissionbinder-example.yaml

# Verify adoption
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager \
  | jq 'select(.action=="adoption")'
```

See [RUNBOOK.md](docs/RUNBOOK.md) for complete troubleshooting guide.

---

## Contributing

We welcome contributions! Please open an issue or pull request on GitHub.

### Development Setup

```bash
# Clone repository
git clone https://github.com/lukasz-bielinski/permission-binder-operator
cd permission-binder-operator/operator

# Run locally
make install
make run
```

---

## License

Apache License 2.0 - See [LICENSE](LICENSE)

---

## Support

- **Documentation:** [docs/](docs/)
- **Issues:** [GitHub Issues](https://github.com/lukasz-bielinski/permission-binder-operator/issues)
- **Security:** See [SECURITY.md](SECURITY.md) for reporting vulnerabilities

---

## Project Status

**Status:** Production Ready ✅  
**Version:** v1.5.7  
**Last Updated:** 2025-10-30  
**Maintainer:** [Łukasz Bieliński](https://github.com/lukasz-bielinski)

### Recent Changes (v1.5.7)
- ✅ **ServiceAccount Management** - Automated SA creation for CI/CD pipelines
- ✅ **Image Signing** - Cosign + GitHub Attestations with SLSA provenance
- ✅ **Race Condition Fixes** - excludeList processing improvements
- ✅ **Test Infrastructure** - Modular test runner with 35 scenarios
- ✅ **Prometheus ServiceMonitor** - Automated metrics collection
- ✅ **Startup Optimization** - Reduced from ~15s to ~3-5s
- ✅ **Documentation** - 100% coverage for all features

---

## Roadmap

- [ ] Custom Resource validation webhooks
- [ ] Multi-PermissionBinder support (separate namespaces)
- [ ] Metric dashboards auto-provisioning
- [ ] Automated DR testing
- [ ] Performance optimizations for 1000+ entries

---

**Built with ❤️ for secure, reliable RBAC management**



