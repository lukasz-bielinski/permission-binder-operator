# Permission Binder Operator

**Production-Grade Kubernetes Operator for Enterprise Environments**

A safe, predictable, and auditable Kubernetes operator that automatically manages RBAC RoleBindings based on ConfigMap entries.

[![Docker Hub](https://img.shields.io/docker/v/lukaszbielinski/permission-binder-operator?label=Docker%20Hub)](https://hub.docker.com/r/lukaszbielinski/permission-binder-operator)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

---

## 🏢 Production-Grade Features

### Security
- ✅ **ClusterRole Validation** - Warns when ClusterRole doesn't exist (security critical)
- ✅ **SAFE MODE** - Never deletes namespaces or RoleBindings accidentally
- ✅ **Finalizer Protection** - Proper cleanup sequence prevents cascade failures
- ✅ **Override Protection** - Enforces desired state (prevents manual tampering)
- ✅ **Audit Trail** - All operations logged in JSON for SIEM integration

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
7. **Reconciliation** - Continuously ensures desired state

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
- [E2E Test Scenarios](example/e2e-test-scenarios.md) - 24 test scenarios
- [Monitoring Guide](example/monitoring/README.md) - Metrics, alerts, dashboards

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

```bash
# Run unit tests
make test

# Run E2E tests
cd example/tests
./test-concurrent.sh
./generate-large-configmap.sh

# See all test scenarios
cat example/e2e-test-scenarios.md
```

---

## Production Deployment

### Requirements
- Single replica (NOT HA) - leader election disabled
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
**Version:** 1.0.0  
**Last Updated:** 2025-10-22  
**Maintainer:** [Łukasz Bieliński](https://github.com/lukasz-bielinski)

### Recent Changes
- ✅ JSON structured logging
- ✅ Custom Prometheus metrics (6 metrics)
- ✅ ClusterRole validation with security warnings
- ✅ Orphaned resource adoption
- ✅ Comprehensive monitoring (Loki + Prometheus + Grafana)
- ✅ Production-grade documentation (Runbook + DR)
- ✅ E2E test suite (24 scenarios)

---

## Roadmap

- [ ] Custom Resource validation webhooks
- [ ] Multi-PermissionBinder support (separate namespaces)
- [ ] Metric dashboards auto-provisioning
- [ ] Automated DR testing
- [ ] Performance optimizations for 1000+ entries

---

**Built with ❤️ for secure, reliable RBAC management**



