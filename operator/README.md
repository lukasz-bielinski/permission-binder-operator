# Permission Binder Operator

A Kubernetes operator that automatically creates RoleBindings based on changes in ConfigMap.

## Description

Permission Binder Operator monitors ConfigMap and creates RoleBindings in appropriate namespaces based on entries. The operator parses ConfigMap keys according to a specified format and maps them to existing ClusterRoles.

## Data Format

ConfigMap should contain a `whitelist.txt` key with LDAP Distinguished Name (DN) entries:

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
```

**Format Details:**
- Each line must contain a valid LDAP DN starting with `CN=`
- The CN value is extracted and parsed as `{PREFIX}-{NAMESPACE}-{ROLE}`
- Empty lines and lines starting with `#` are ignored (comments)

**Example:**
```
Input LDAP DN: CN=COMPANY-K8S-project1-engineer,OU=Kubernetes,...
Extracted CN:  COMPANY-K8S-project1-engineer
Parsed as:     Prefix=COMPANY-K8S, Namespace=project1, Role=engineer

Input LDAP DN: CN=MT-K8S-tenant1-project-3121-engineer,OU=...
Extracted CN:  MT-K8S-tenant1-project-3121-engineer
Parsed as:     Prefix=MT-K8S, Namespace=tenant1-project-3121, Role=engineer
```

**Parsing Logic:**
- Prefix is defined in PermissionBinder CR (`spec.prefix`)
- Role is matched against keys in `spec.roleMapping`
- Namespace is everything between prefix and role (can contain hyphens)
- If multiple roles match, the longest role name is used

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
  whitelist.txt: |-
    CN=COMPANY-K8S-project1-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-project2-admin,OU=Kubernetes,OU=Platform,DC=example,DC=com
    CN=COMPANY-K8S-project3-viewer,OU=Kubernetes,OU=Platform,DC=example,DC=com
    # CN=COMPANY-K8S-HPA-admin - Excluded via ExcludeList
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
2. For each line in `whitelist.txt`:
   - Extracts CN value from LDAP DN format
   - Checks if the CN is not on the exclusion list
   - Parses the CN to extract prefix, namespace and role
   - Validates the role exists in roleMapping
   - Creates namespace if it doesn't exist
   - Creates RoleBinding in the appropriate namespace
3. RoleBinding links the LDAP group (full DN) with ClusterRole (from mapping)

## Status

Operator tracks status in PermissionBinder:
- `processedRoleBindings` - list of created RoleBindings
- `lastProcessedConfigMapVersion` - version of last processed ConfigMap
- `conditions` - status conditions

## Requirements

- Kubernetes 1.19+
- Existing ClusterRoles for mapping