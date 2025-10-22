# Permission Binder Operator

A Kubernetes operator that automatically creates RoleBindings based on changes in ConfigMap.

## Description

Permission Binder Operator monitors ConfigMap and creates RoleBindings in appropriate namespaces based on entries. The operator parses ConfigMap keys according to a specified format and maps them to existing ClusterRoles.

## Data Format

ConfigMap should contain keys in the format:
```
{PREFIX}-{NAMESPACE}-{ROLE}
```

Example:
```
COMPANY-K8S-project1-engineer
COMPANY-K8S-project2-admin
```

Where:
- `COMPANY-K8S` - prefix
- `project1`, `project2` - namespace names
- `engineer`, `admin` - roles to map to ClusterRoles

## Configuration

### PermissionBinder Custom Resource

```yaml
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: permissionbinder-sample
spec:
  roleMapping:
    engineer: clusterrole-engineer
    admin: clusterrole-admin
    viewer: clusterrole-viewer
  prefix: "COMPANY-K8S"
  excludeList:
    - "COMPANY-K8S-HPA-admin"
  configMapName: "permission-config"
  configMapNamespace: "default"
```

### ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config
  namespace: default
data:
  COMPANY-K8S-project1-engineer: "COMPANY-K8S-project1-engineer"
  COMPANY-K8S-project2-admin: "COMPANY-K8S-project2-admin"
  COMPANY-K8S-project3-viewer: "COMPANY-K8S-project3-viewer"
  COMPANY-K8S-HPA-admin: "COMPANY-K8S-HPA-admin"  # Excluded
```

## Installation

1. Install CRD:
```bash
make install
```

2. Run operator:
```bash
make run
```

3. Apply sample resources:
```bash
kubectl apply -f config/samples/configmap-example.yaml
kubectl apply -f config/samples/permission_v1_permissionbinder.yaml
```

## Multi-Architecture Build

The operator supports building Docker images for multiple architectures (aarch64 and x86_64).

### Option 1: Using Makefile

```bash
# Build and push multi-arch image
make multi-arch-build IMG=lukaszbielinski/permission-binder-operator:latest

# Build local multi-arch image (without push)
make multi-arch-build-local IMG=lukaszbielinski/permission-binder-operator:latest
```

### Option 2: Using scripts

```bash
# Build and push multi-arch image
./scripts/build-multi-arch.sh latest

# Build local multi-arch image (without push)
./scripts/build-multi-arch-local.sh latest
```

### Requirements

- Docker with BuildKit enabled
- Docker buildx plugin
- Logged in to Docker Hub (for push)

### Verification

```bash
# Check image architectures
docker buildx imagetools inspect lukaszbielinski/permission-binder-operator:latest
```

## Static Binaries

The operator can also be built as static Go binaries:

### Option 1: Using Makefile

```bash
# Build static binaries for all architectures
make build-static

# Build static binaries for specific architecture
make build-static-amd64
make build-static-arm64
```

### Option 2: Manual building

```bash
# AMD64
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -ldflags '-extldflags "-static"' -o bin/manager-amd64 cmd/main.go

# ARM64
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -a -ldflags '-extldflags "-static"' -o bin/manager-arm64 cmd/main.go
```

### Static binaries verification

```bash
# Check if binaries are static
file bin/manager-*
ldd bin/manager-amd64  # Should show "No dynamic dependencies"
```

## Operation Logic

1. Operator monitors changes in ConfigMap
2. For each key in ConfigMap:
   - Checks if it starts with the specified prefix
   - Checks if it's not on the exclusion list
   - Parses the key to extract namespace and role
   - Creates namespace if it doesn't exist
   - Creates RoleBinding in the appropriate namespace
3. RoleBinding links the group (value from ConfigMap) with ClusterRole (from mapping)

## Status

Operator tracks status in PermissionBinder:
- `processedRoleBindings` - list of created RoleBindings
- `lastProcessedConfigMapVersion` - version of last processed ConfigMap
- `conditions` - status conditions

## Requirements

- Kubernetes 1.19+
- Existing ClusterRoles for mapping