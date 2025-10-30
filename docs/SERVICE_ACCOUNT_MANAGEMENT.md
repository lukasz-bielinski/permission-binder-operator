# ServiceAccount Management

The Permission Binder Operator can automatically create and manage ServiceAccounts for CI/CD pipelines and application pods, along with their RoleBindings.

## Table of Contents

- [Overview](#overview)
- [Configuration](#configuration)
- [Naming Patterns](#naming-patterns)
- [Use Cases](#use-cases)
- [CI/CD Integration](#cicd-integration)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)

## Overview

ServiceAccount management automates the creation of:
- **ServiceAccounts** for automation and application pods
- **RoleBindings** that grant appropriate permissions to these ServiceAccounts

### Key Features

✅ **Automatic Creation**: ServiceAccounts are created for each namespace that has whitelist entries  
✅ **Idempotent**: Checks if ServiceAccount exists before creating  
✅ **Configurable Naming**: Customize naming patterns with variables  
✅ **Role Flexibility**: Support for both ClusterRoles and namespace-scoped Roles  
✅ **Monitoring**: Prometheus metrics for tracking ServiceAccount operations  
✅ **Status Tracking**: Lists all managed ServiceAccounts in CR status  

### How It Works

```
ConfigMap Whitelist Entry
   ↓
Namespace Identified: my-app
   ↓
Create RoleBindings for LDAP Groups (existing logic)
   ↓
FOR EACH ServiceAccountMapping entry:
   ├─ Generate SA name: my-app-sa-deploy
   ├─ Create ServiceAccount (if not exists)
   ├─ Create RoleBinding: sa-my-app-deploy
   └─ Track in status.processedServiceAccounts
```

## Configuration

### Basic Example

```yaml
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: example
  namespace: permissions-binder-operator
spec:
  configMapName: permission-config
  configMapNamespace: permissions-binder-operator
  
  prefixes:
    - "COMPANY-K8S"
  
  roleMapping:
    admin: cluster-admin
    developer: edit
    viewer: view
  
  # ServiceAccount configuration
  serviceAccountMapping:
    deploy: edit      # CI/CD deployment account
    runtime: view     # Application pod account
  
  serviceAccountNamingPattern: "{namespace}-sa-{name}"  # Optional
```

### ServiceAccountMapping

The `serviceAccountMapping` field defines which ServiceAccounts to create and what roles to assign.

**Format**: `<name>: <role-name>`

- `<name>`: The ServiceAccount type (e.g., deploy, runtime, backup)
- `<role-name>`: The ClusterRole name to bind (e.g., edit, view, admin)

**Examples**:

```yaml
serviceAccountMapping:
  deploy: edit              # Full edit permissions for deployments
  runtime: view             # Read-only for application pods
  backup: backup-operator   # Custom backup role
  monitor: monitoring       # Custom monitoring role
```

### ServiceAccountNamingPattern

Controls how ServiceAccount names are generated.

**Default**: `{namespace}-sa-{name}`

**Available Variables**:
- `{namespace}`: The Kubernetes namespace name
- `{name}`: The ServiceAccount type from mapping key

**Pattern Examples**:

| Pattern | Example Output | Use Case |
|---------|----------------|----------|
| `{namespace}-sa-{name}` | `my-app-sa-deploy` | **Recommended**: Clear identification |
| `sa-{namespace}-{name}` | `sa-my-app-deploy` | SA prefix for grouping |
| `{namespace}-{name}` | `my-app-deploy` | Shorter names |
| `{name}-{namespace}` | `deploy-my-app` | Role-based grouping |

**Configuration**:

```yaml
spec:
  serviceAccountMapping:
    deploy: edit
    runtime: view
  
  # Choose your pattern:
  serviceAccountNamingPattern: "{namespace}-sa-{name}"  # Default (recommended)
  # serviceAccountNamingPattern: "sa-{namespace}-{name}"
  # serviceAccountNamingPattern: "{namespace}-{name}"
```

## Naming Patterns

### Pattern Selection Guide

#### Pattern 1: `{namespace}-sa-{name}` (Default - Recommended)

```yaml
serviceAccountNamingPattern: "{namespace}-sa-{name}"
```

**Creates**: `my-app-sa-deploy`, `my-app-sa-runtime`

**Pros**:
- ✅ Clear identification of ServiceAccounts
- ✅ Namespace-first sorting in kubectl output
- ✅ "sa" marker clearly indicates it's a ServiceAccount
- ✅ Production-tested and recommended

**Best for**: Multi-tenant environments, production systems

#### Pattern 2: `sa-{namespace}-{name}`

```yaml
serviceAccountNamingPattern: "sa-{namespace}-{name}"
```

**Creates**: `sa-my-app-deploy`, `sa-my-app-runtime`

**Pros**:
- ✅ ServiceAccounts grouped together in sorted lists
- ✅ Clear "sa" prefix

**Best for**: Environments with many resource types

#### Pattern 3: `{namespace}-{name}`

```yaml
serviceAccountNamingPattern: "{namespace}-{name}"
```

**Creates**: `my-app-deploy`, `my-app-runtime`

**Pros**:
- ✅ Shorter names
- ✅ Less typing

**Cons**:
- ⚠️ Harder to distinguish from other resources

**Best for**: Simple environments, internal tools

#### Pattern 4: `{name}-{namespace}`

```yaml
serviceAccountNamingPattern: "{name}-{namespace}"
```

**Creates**: `deploy-my-app`, `runtime-my-app`

**Pros**:
- ✅ Groups by role type (all deploy SAs together)

**Best for**: Role-based organization

### Pattern Best Practices

1. **Include "sa" identifier**: Makes it clear these are ServiceAccounts
2. **Start with namespace**: Better for multi-tenant environments
3. **Be consistent**: Use the same pattern across your organization
4. **Document your choice**: Include naming convention in your docs

## Use Cases

### 1. CI/CD Deployment Account

**Purpose**: Automated deployments from Bamboo, Jenkins, GitLab CI

**Configuration**:
```yaml
serviceAccountMapping:
  deploy: edit
```

**Creates**: `my-app-sa-deploy` with `edit` ClusterRole

**Permissions**: Can create, update, delete resources in namespace

**Usage in Bamboo**:
```bash
#!/bin/bash
NAMESPACE="my-app"
SA_NAME="${NAMESPACE}-sa-deploy"

# Get token
TOKEN=$(oc sa get-token $SA_NAME -n $NAMESPACE)

# Deploy
oc login --token=$TOKEN --server=https://api.cluster.example.com:6443
oc apply -f deployment.yaml -n $NAMESPACE
```

### 2. Application Runtime Account

**Purpose**: For application pods that need to read Kubernetes resources

**Configuration**:
```yaml
serviceAccountMapping:
  runtime: view
```

**Creates**: `my-app-sa-runtime` with `view` ClusterRole

**Permissions**: Read-only access to namespace resources

**Usage in Deployment**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-app
spec:
  template:
    spec:
      serviceAccountName: my-app-sa-runtime
      containers:
      - name: app
        image: my-app:latest
```

### 3. Backup Job Account

**Purpose**: Scheduled backup jobs

**Configuration**:
```yaml
serviceAccountMapping:
  backup: backup-operator
```

**Creates**: `my-app-sa-backup` with custom `backup-operator` ClusterRole

### 4. Monitoring Agent Account

**Purpose**: Prometheus/monitoring agents

**Configuration**:
```yaml
serviceAccountMapping:
  monitor: monitoring
```

**Creates**: `my-app-sa-monitor` with custom `monitoring` ClusterRole

## CI/CD Integration

### Bamboo Integration

**Bamboo Plan Script**:

```bash
#!/bin/bash
# Bamboo deployment using ServiceAccount

set -e

NAMESPACE="${bamboo.deployment.namespace}"
APP_NAME="${bamboo.deployment.name}"
SA_NAME="${NAMESPACE}-sa-deploy"
OPENSHIFT_SERVER="https://api.cluster.example.com:6443"

echo "=== Deploying ${APP_NAME} to ${NAMESPACE} ==="

# Get ServiceAccount token
echo "Getting token for ServiceAccount: $SA_NAME"
TOKEN=$(oc sa get-token $SA_NAME -n $NAMESPACE)

# Login using ServiceAccount
echo "Logging in to OpenShift..."
oc login --token=$TOKEN --server=$OPENSHIFT_SERVER

# Verify namespace access
oc project $NAMESPACE

# Deploy application
echo "Deploying application..."
oc apply -f deployment.yaml -n $NAMESPACE

# Wait for rollout
echo "Waiting for rollout..."
oc rollout status deployment/$APP_NAME -n $NAMESPACE --timeout=5m

echo "=== Deployment complete ==="
```

**Bamboo Variables**:
- `bamboo.deployment.namespace`: Target namespace
- `bamboo.deployment.name`: Application name

### GitLab CI/CD

**.gitlab-ci.yml**:

```yaml
variables:
  NAMESPACE: "my-app"
  OPENSHIFT_SERVER: "https://api.cluster.example.com:6443"

deploy:
  stage: deploy
  image: quay.io/openshift/origin-cli:latest
  script:
    # Get ServiceAccount token
    - export SA_NAME="${NAMESPACE}-sa-deploy"
    - export TOKEN=$(oc sa get-token ${SA_NAME} -n ${NAMESPACE})
    
    # Login and deploy
    - oc login --token=${TOKEN} --server=${OPENSHIFT_SERVER}
    - oc apply -f deployment.yaml -n ${NAMESPACE}
    - oc rollout status deployment/my-app -n ${NAMESPACE}
  
  only:
    - main
  
  environment:
    name: production
    kubernetes:
      namespace: my-app
```

### Jenkins Pipeline

**Jenkinsfile**:

```groovy
pipeline {
    agent any
    
    environment {
        NAMESPACE = 'my-app'
        SA_NAME = "${NAMESPACE}-sa-deploy"
        OPENSHIFT_SERVER = 'https://api.cluster.example.com:6443'
    }
    
    stages {
        stage('Deploy') {
            steps {
                script {
                    // Get ServiceAccount token
                    def token = sh(
                        script: "oc sa get-token ${SA_NAME} -n ${NAMESPACE}",
                        returnStdout: true
                    ).trim()
                    
                    // Login
                    sh "oc login --token=${token} --server=${OPENSHIFT_SERVER}"
                    
                    // Deploy
                    sh """
                        oc apply -f deployment.yaml -n ${NAMESPACE}
                        oc rollout status deployment/my-app -n ${NAMESPACE}
                    """
                }
            }
        }
    }
}
```

### GitHub Actions

**.github/workflows/deploy.yml**:

```yaml
name: Deploy to OpenShift

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Install OpenShift CLI
        uses: redhat-actions/oc-installer@v1
      
      - name: Deploy to OpenShift
        env:
          NAMESPACE: my-app
          OPENSHIFT_SERVER: https://api.cluster.example.com:6443
        run: |
          # Get ServiceAccount token
          SA_NAME="${NAMESPACE}-sa-deploy"
          TOKEN=$(oc sa get-token ${SA_NAME} -n ${NAMESPACE})
          
          # Login and deploy
          oc login --token=${TOKEN} --server=${OPENSHIFT_SERVER}
          oc apply -f deployment.yaml -n ${NAMESPACE}
          oc rollout status deployment/my-app -n ${NAMESPACE}
```

## Monitoring

### Prometheus Metrics

The operator exposes metrics for ServiceAccount operations:

#### serviceAccountsCreated

**Counter**: Tracks total number of ServiceAccounts created

```promql
# Total ServiceAccounts created by namespace
permission_binder_service_accounts_created_total{namespace="my-app", sa_type="deploy"}

# Rate of ServiceAccount creation
rate(permission_binder_service_accounts_created_total[5m])

# Count by SA type
sum by (sa_type) (permission_binder_service_accounts_created_total)
```

**Labels**:
- `namespace`: Kubernetes namespace
- `sa_type`: ServiceAccount type (deploy, runtime, etc.)

#### managedServiceAccountsTotal

**Gauge**: Current number of ServiceAccounts managed by the operator

```promql
# Current managed ServiceAccounts
permission_binder_managed_service_accounts_total

# Alert on unexpected changes
abs(delta(permission_binder_managed_service_accounts_total[5m])) > 10
```

### Grafana Dashboard Queries

**ServiceAccounts by Namespace**:
```promql
sum by (namespace) (permission_binder_service_accounts_created_total)
```

**ServiceAccounts by Type**:
```promql
sum by (sa_type) (permission_binder_service_accounts_created_total)
```

**ServiceAccount Creation Rate**:
```promql
rate(permission_binder_service_accounts_created_total[1h])
```

### Status Tracking

Check the PermissionBinder status to see managed ServiceAccounts:

```bash
kubectl get permissionbinder example -n permissions-binder-operator -o yaml
```

```yaml
status:
  processedRoleBindings:
    - my-app/my-app-developer
    - my-app/my-app-admin
  processedServiceAccounts:
    - my-app/my-app-sa-deploy
    - my-app/my-app-sa-runtime
    - other-app/other-app-sa-deploy
    - other-app/other-app-sa-runtime
  conditions:
    - type: Processed
      status: "True"
      lastTransitionTime: "2025-10-29T10:15:30Z"
      reason: ConfigMapProcessed
      message: "Successfully processed 2 role bindings and 4 service accounts"
```

## Troubleshooting

### ServiceAccount Not Created

**Check operator logs**:
```bash
kubectl logs -n permissions-binder-operator deployment/permission-binder-operator-controller-manager -f
```

**Look for**:
```
🔑 ServiceAccount mapping configured, creating ServiceAccounts
Creating ServiceAccount: my-app-sa-deploy in namespace my-app
✅ ServiceAccount created/verified: my-app/my-app-sa-deploy
```

**Common issues**:
1. **No whitelist entries**: ServiceAccounts only created for namespaces with whitelist entries
2. **RBAC permissions**: Operator needs `serviceaccounts` permissions
3. **Namespace not found**: Namespace must exist before SA creation

### RoleBinding Not Created

**Check**:
```bash
# List RoleBindings for ServiceAccount
kubectl get rolebinding -n my-app | grep sa-deploy

# Describe specific RoleBinding
# RoleBinding naming: sa-{namespace}-{sa-key}
kubectl describe rolebinding sa-my-app-deploy -n my-app
```

**Expected output**:
```yaml
Name:         sa-my-app-deploy
Namespace:    my-app
Role:
  Kind:  ClusterRole
  Name:  edit
Subjects:
  Kind            Name               Namespace
  ----            ----               ---------
  ServiceAccount  my-app-sa-deploy   my-app
```

### Token Extraction Issues

**Get ServiceAccount token**:

```bash
# OpenShift 4.x
oc sa get-token my-app-sa-deploy -n my-app

# Kubernetes with TokenRequest API
kubectl create token my-app-sa-deploy -n my-app --duration=1h
```

**If token command fails**:
```bash
# Check if ServiceAccount exists
kubectl get sa my-app-sa-deploy -n my-app

# Check if SA has secrets (legacy)
kubectl get sa my-app-sa-deploy -n my-app -o jsonpath='{.secrets[*].name}'
```

### Permission Denied in CI/CD

**Check RoleBinding**:
```bash
oc describe rolebinding sa-my-app-deploy -n my-app
```

**Verify role permissions**:
```bash
# What can the SA do?
oc auth can-i --list --as=system:serviceaccount:my-app:my-app-sa-deploy -n my-app
```

**Test deployment**:
```bash
# Get token
TOKEN=$(oc sa get-token my-app-sa-deploy -n my-app)

# Try to apply
oc login --token=$TOKEN --server=https://api.cluster.example.com:6443
oc apply -f test-deployment.yaml -n my-app
```

### ServiceAccount Pattern Not Working

**Verify pattern syntax**:
```bash
# Check PermissionBinder spec
kubectl get permissionbinder example -n permissions-binder-operator -o jsonpath='{.spec.serviceAccountNamingPattern}'
```

**Expected output**: `{namespace}-sa-{name}`

**Test pattern manually**:
- Pattern: `{namespace}-sa-{name}`
- Namespace: `my-app`
- Name: `deploy`
- Expected: `my-app-sa-deploy`

### Metrics Not Appearing

**Check Prometheus scraping**:
```bash
# Check if operator endpoint is reachable
kubectl port-forward -n permissions-binder-operator deployment/permission-binder-operator-controller-manager 8080:8080

# Query metrics
curl http://localhost:8080/metrics | grep permission_binder_service_accounts
```

**Expected metrics**:
```
permission_binder_service_accounts_created_total{namespace="my-app",sa_type="deploy"} 1
permission_binder_managed_service_accounts_total 4
```

## Security Best Practices

### 1. Least Privilege

✅ **DO**:
- Use `view` role for application pods (read-only)
- Use `edit` role for CI/CD (namespace-scoped)
- Create custom roles for specific needs

❌ **DON'T**:
- Use `cluster-admin` for ServiceAccounts
- Grant more permissions than necessary
- Share ServiceAccount tokens across projects

### 2. Token Management

✅ **DO**:
- Fetch fresh tokens for each CI/CD run
- Use short-lived tokens (with `--duration` flag)
- Rotate tokens regularly

❌ **DON'T**:
- Store tokens in plain text
- Use tokens in version control
- Cache tokens long-term

### 3. Namespace Isolation

✅ **DO**:
- Create separate ServiceAccounts per namespace
- Use namespace-scoped Roles when possible
- Monitor cross-namespace access attempts

❌ **DON'T**:
- Share ServiceAccounts across namespaces
- Grant cluster-wide access unless necessary

### 4. Audit and Monitoring

✅ **DO**:
- Enable audit logging
- Monitor ServiceAccount usage with Prometheus
- Alert on suspicious activity
- Review ServiceAccount permissions regularly

❌ **DON'T**:
- Ignore failed authentication attempts
- Skip log analysis

### 5. Naming Conventions

✅ **DO**:
- Use clear, descriptive naming patterns
- Include "sa" marker in names
- Document your naming convention

❌ **DON'T**:
- Use generic names (e.g., `default`)
- Change patterns frequently

## Examples

See `example/examples/` directory:
- `permissionbinder-with-service-accounts.yaml` - Basic configuration
- `permissionbinder-with-custom-sa-pattern.yaml` - Custom naming patterns
- `ci-cd-integration-example.yaml` - Complete CI/CD integration guide

## Related Documentation

- [LDAP Integration](LDAP_INTEGRATION.md) - LDAP group creation
- [RHACS Setup](../example/rhacs/README.md) - Image signature verification
- [E2E Test Scenarios](../example/e2e-test-scenarios.md) - Testing guide

