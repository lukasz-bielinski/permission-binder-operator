# Permission Binder Operator - GitOps Deployment

This directory contains all files needed to deploy Permission Binder Operator using GitOps (ArgoCD).

## Directory Structure

```
example/
├── crd/                                    # Custom Resource Definitions
│   └── permission.permission-binder.io_permissionbinders.yaml
├── deployment/                             # Operator deployment
│   ├── operator-deployment.yaml
│   └── servicemonitor.yaml                 # Prometheus metrics
├── monitoring/                             # Monitoring configuration
│   ├── servicemonitor.yaml                 # Prometheus ServiceMonitor
│   └── ...
├── configmap/                              # Example ConfigMap
│   └── permission-config.yaml
├── permissionbinder/                       # Example PermissionBinder CR
│   └── permissionbinder-example.yaml
├── examples/                               # Feature examples
│   ├── permissionbinder-with-service-accounts.yaml
│   ├── permissionbinder-with-ldap.yaml
│   └── ci-cd-integration-example.yaml
├── tests/                                  # E2E test suite
│   ├── run-all-individually.sh
│   ├── test-runner.sh
│   └── README.md
├── kustomization.yaml                      # Kustomize manifest
├── argocd-application.yaml                 # ArgoCD Application
├── e2e-test-scenarios.md                   # Test documentation (35 scenarios)
└── README.md                               # This file
```

## Deployment

### Option 1: ArgoCD Application

1. Apply ArgoCD Application:
```bash
kubectl apply -f argocd-application.yaml
```

2. Check status in ArgoCD UI or CLI:
```bash
argocd app get permission-binder-operator
```

### Option 2: Manual deployment

1. Apply all manifests:
```bash
kubectl apply -k .
```

2. Check status:
```bash
kubectl get permissionbinders
kubectl get pods -l app.kubernetes.io/name=permission-binder-operator
```

### Option 3: Deployment for different environments

#### Staging
```bash
kubectl apply -k environments/staging/
```

#### Production
```bash
kubectl apply -k environments/production/
```

## Configuration

### ConfigMap

Edit `configmap/permission-config.yaml` to add your permissions:

```yaml
data:
  COMPANY-K8S-project1-engineer: "COMPANY-K8S-project1-engineer"
  COMPANY-K8S-project2-admin: "COMPANY-K8S-project2-admin"
  # ... more permissions
```

### PermissionBinder CR

Edit `permissionbinder/permissionbinder-example.yaml` to configure:

- `roleMapping` - mapping of roles to ClusterRoles
- `prefix` - prefix for permission strings
- `excludeList` - exclusion list
- `configMapName` and `configMapNamespace` - ConfigMap configuration

## Verification

After deployment, check:

1. **Operator status:**
```bash
kubectl get pods -l app.kubernetes.io/name=permission-binder-operator
```

2. **Created namespaces:**
```bash
kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator
```

3. **Created RoleBindings:**
```bash
kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator
```

4. **Operator logs:**
```bash
kubectl logs -l app.kubernetes.io/name=permission-binder-operator
```

## Customization

### Changing operator image

Edit `deployment/operator-deployment.yaml` and change:
```yaml
spec:
  template:
    spec:
      containers:
      - name: manager
        image: lukaszbielinski/permission-binder-operator:latest
```

### Adding new roles

1. Add new role to `roleMapping` in PermissionBinder CR
2. Ensure the corresponding ClusterRole exists in the cluster
3. Add permissions to ConfigMap

### Changing namespace

Edit `kustomization.yaml` and change:
```yaml
namespace: your-namespace
```

## Troubleshooting

### Operator doesn't start

```bash
kubectl describe pod -l app.kubernetes.io/name=permission-binder-operator
kubectl logs -l app.kubernetes.io/name=permission-binder-operator
```

### Missing permissions

Check if the operator has appropriate RBAC permissions in `deployment/operator-deployment.yaml`.

### ConfigMap not being read

Check if:
1. ConfigMap exists in the appropriate namespace
2. Name and namespace in PermissionBinder CR are correct
3. Operator has permissions to read ConfigMap
