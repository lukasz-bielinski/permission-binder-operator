# ArgoCD Deployment Guide

This guide describes how to deploy Permission Binder Operator using ArgoCD.

## Requirements

- ArgoCD installed in the cluster
- Access to Git repository with manifests
- Permissions to create Application in ArgoCD

## ArgoCD Configuration

### 1. Creating Application

Apply Application manifest:

```bash
kubectl apply -f argocd-application.yaml
```

### 2. Configuration using ArgoCD CLI

```bash
# Create Application
argocd app create permission-binder-operator \
  --repo https://github.com/your-org/permission-binder-operator.git \
  --path example \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default \
  --sync-policy automated \
  --auto-prune \
  --self-heal

# Check status
argocd app get permission-binder-operator

# Synchronize
argocd app sync permission-binder-operator
```

### 3. Configuration using ArgoCD UI

1. Open ArgoCD UI
2. Click "New App"
3. Fill the form:
   - **Application Name**: `permission-binder-operator`
   - **Project**: `default`
   - **Sync Policy**: `Automatic`
   - **Repository URL**: `https://github.com/your-org/permission-binder-operator.git`
   - **Path**: `example`
   - **Cluster**: `https://kubernetes.default.svc`
   - **Namespace**: `default`

## Configuration for different environments

### Staging

```bash
argocd app create permission-binder-operator-staging \
  --repo https://github.com/your-org/permission-binder-operator.git \
  --path example/environments/staging \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace permission-binder-staging \
  --sync-policy automated
```

### Production

```bash
argocd app create permission-binder-operator-production \
  --repo https://github.com/your-org/permission-binder-operator.git \
  --path example/environments/production \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace permission-binder-system \
  --sync-policy automated
```

## Monitoring

### Status check

```bash
# Application status
argocd app get permission-binder-operator

# Synchronization logs
argocd app logs permission-binder-operator

# Synchronization history
argocd app history permission-binder-operator
```

### Cluster resources check

```bash
# Check CRD
kubectl get crd permissionbinders.permission.permission-binder.io

# Check operator
kubectl get pods -l app.kubernetes.io/name=permission-binder-operator

# Check PermissionBinder
kubectl get permissionbinders

# Check created namespaces
kubectl get namespaces -l permission-binder.io/managed-by=permission-binder-operator

# Check RoleBindings
kubectl get rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator
```

## Troubleshooting

### Application not synchronizing

1. Check logs:
```bash
argocd app logs permission-binder-operator
```

2. Check status:
```bash
argocd app get permission-binder-operator
```

3. Force synchronization:
```bash
argocd app sync permission-binder-operator --force
```

### Operator not starting

1. Check operator logs:
```bash
kubectl logs -l app.kubernetes.io/name=permission-binder-operator
```

2. Check RBAC:
```bash
kubectl describe clusterrole permission-binder-operator-manager-role
kubectl describe clusterrolebinding permission-binder-operator-manager-rolebinding
```

### Missing permissions

Check if the operator has appropriate permissions:
```bash
kubectl auth can-i create rolebindings --as=system:serviceaccount:default:permission-binder-operator-controller-manager
kubectl auth can-i create namespaces --as=system:serviceaccount:default:permission-binder-operator-controller-manager
```

## Updates

### Operator image update

1. Edit `deployment/operator-deployment.yaml` or appropriate file in `environments/`
2. Commit changes to Git
3. ArgoCD will automatically synchronize changes

### Configuration update

1. Edit appropriate files in `example/` directory
2. Commit changes to Git
3. ArgoCD will automatically synchronize changes

## Best Practices

1. **Use image tags** instead of `latest` in production environment
2. **Test changes** in staging environment before deploying to production
3. **Monitor logs** regularly
4. **Backup configuration** before major changes
5. **Use sync waves** to control resource deployment order
