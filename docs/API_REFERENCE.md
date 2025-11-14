# Permission Binder Operator - API Reference

## Table of Contents

1. [PermissionBinder CRD](#permissionbinder-crd)
2. [Spec Fields](#spec-fields)
3. [Status Fields](#status-fields)
4. [Examples](#examples)
5. [Field Reference](#field-reference)

## PermissionBinder CRD

### Overview

The `PermissionBinder` Custom Resource Definition (CRD) is the primary API for configuring the Permission Binder Operator. It defines how LDAP groups are mapped to Kubernetes RBAC and how NetworkPolicies are managed via GitOps.

**API Version**: `permission.permission-binder.io/v1`  
**Kind**: `PermissionBinder`

### Full CRD Schema

```yaml
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: <instance-name>
  namespace: <operator-namespace>
spec:
  # RBAC Configuration
  roleMapping: <map[string]string>
  prefixes: <[]string>
  excludeList: <[]string>
  configMapName: <string>
  configMapNamespace: <string>
  
  # LDAP Configuration
  createLdapGroups: <bool>
  ldapSecretRef: <LdapSecretReference>
  ldapTlsVerify: <*bool>
  
  # ServiceAccount Configuration
  serviceAccountMapping: <map[string]string>
  serviceAccountNamingPattern: <string>
  
  # NetworkPolicy Configuration
  networkPolicy: <NetworkPolicySpec>
status:
  # Observed State
  processedRoleBindings: <[]string>
  processedServiceAccounts: <[]string>
  lastProcessedConfigMapVersion: <string>
  lastProcessedRoleMappingHash: <string>
  conditions: <[]metav1.Condition>
  networkPolicies: <[]NetworkPolicyStatus>
  lastNetworkPolicyReconciliation: <*metav1.Time>
```

## Spec Fields

### RBAC Configuration

#### `roleMapping` (required)

**Type**: `map[string]string`  
**Description**: Maps role names to existing Kubernetes ClusterRoles.

**Format**: `"<role-name>": "<clusterrole-name>"`

**Example**:
```yaml
roleMapping:
  engineer: edit
  viewer: view
  admin: admin
  deploy: edit
  runtime: view
```

**Validation**:
- Required field
- Keys must be non-empty strings
- Values must reference existing ClusterRoles
- Operator validates ClusterRole existence at runtime

**Behavior**:
- Used to map roles extracted from LDAP DNs to ClusterRoles
- Example: `CN=COMPANY-K8S-project1-engineer` → `engineer` → `edit` ClusterRole

---

#### `prefixes` (required)

**Type**: `[]string`  
**Description**: Prefixes used to identify permission strings in LDAP DNs.

**Example**:
```yaml
prefixes:
  - COMPANY-K8S
  - MT-K8S
  - DEV-K8S
```

**Validation**:
- Required field
- Minimum 1 item
- Must be non-empty strings

**Behavior**:
- Operator matches LDAP DNs starting with these prefixes
- Example: `CN=COMPANY-K8S-project1-engineer` matches prefix `COMPANY-K8S`
- Supports multi-tenant scenarios (multiple prefixes)

---

#### `excludeList` (optional)

**Type**: `[]string`  
**Description**: CN values to exclude from processing.

**Example**:
```yaml
excludeList:
  - COMPANY-K8S-test-exclude
  - COMPANY-K8S-admin-special
```

**Validation**:
- Optional field
- Array of strings

**Behavior**:
- Exact match against LDAP DN CN values
- Excluded entries are skipped during reconciliation
- Useful for excluding test or special-case entries

---

#### `configMapName` (required)

**Type**: `string`  
**Description**: Name of the ConfigMap containing LDAP group whitelist.

**Example**:
```yaml
configMapName: ldap-whitelist
```

**Validation**:
- Required field
- Must be a valid Kubernetes resource name

**Behavior**:
- Operator watches this ConfigMap for changes
- ConfigMap data contains LDAP DN entries (one per line)
- Changes trigger reconciliation

---

#### `configMapNamespace` (required)

**Type**: `string`  
**Description**: Namespace where the ConfigMap is located.

**Example**:
```yaml
configMapNamespace: permission-binder-system
```

**Validation**:
- Required field
- Must be a valid Kubernetes namespace name

---

### LDAP Configuration

#### `createLdapGroups` (optional)

**Type**: `bool`  
**Default**: `false`  
**Description**: Enables automatic LDAP group creation for namespaces.

**Example**:
```yaml
createLdapGroups: true
```

**Behavior**:
- When enabled, operator creates LDAP groups for each namespace
- Group format: `CN={namespace}-k8s-group,OU=Kubernetes,DC=company,DC=com`
- Requires `ldapSecretRef` to be configured

---

#### `ldapSecretRef` (optional)

**Type**: `LdapSecretReference`  
**Description**: Reference to Secret containing LDAP connection credentials.

**Structure**:
```yaml
ldapSecretRef:
  name: ldap-credentials
  namespace: permission-binder-system
```

**Secret Required Keys**:
- `domain_server`: LDAP server address (e.g., `ldap.company.com:389`)
- `domain_username`: LDAP bind username
- `domain_password`: LDAP bind password

**Example Secret**:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ldap-credentials
  namespace: permission-binder-system
type: Opaque
stringData:
  domain_server: ldap.company.com:389
  domain_username: svc-kubernetes@company.com
  domain_password: <password>
```

---

#### `ldapTlsVerify` (optional)

**Type**: `*bool`  
**Default**: `true`  
**Description**: Enables TLS certificate verification for LDAPS connections.

**Example**:
```yaml
ldapTlsVerify: true  # Secure (default)
ldapTlsVerify: false # Insecure (testing only)
```

**Security Note**: Set to `false` only for testing with self-signed certificates. Production should always use `true`.

---

### ServiceAccount Configuration

#### `serviceAccountMapping` (optional)

**Type**: `map[string]string`  
**Description**: Maps service account names to roles.

**Format**: `"<sa-name>": "<clusterrole-name>"`

**Example**:
```yaml
serviceAccountMapping:
  deploy: edit
  runtime: view
  ci: edit
```

**Behavior**:
- Creates ServiceAccounts with pattern defined by `serviceAccountNamingPattern`
- Example: `deploy: edit` creates SA `{namespace}-sa-deploy` with ClusterRole `edit`
- Also creates RoleBinding linking SA to ClusterRole

---

#### `serviceAccountNamingPattern` (optional)

**Type**: `string`  
**Default**: `"{namespace}-sa-{name}"`  
**Description**: Naming pattern for ServiceAccounts.

**Available Variables**:
- `{namespace}`: Namespace name
- `{name}`: ServiceAccount name from mapping

**Examples**:
```yaml
serviceAccountNamingPattern: "{namespace}-sa-{name}"      # my-app-sa-deploy
serviceAccountNamingPattern: "sa-{namespace}-{name}"      # sa-my-app-deploy
serviceAccountNamingPattern: "{name}-{namespace}"         # deploy-my-app
serviceAccountNamingPattern: "{namespace}-{name}"         # my-app-deploy
```

---

### NetworkPolicy Configuration

#### `networkPolicy` (optional)

**Type**: `NetworkPolicySpec`  
**Description**: NetworkPolicy management configuration.

**Structure**:
```yaml
networkPolicy:
  enabled: <bool>
  gitRepository: <GitRepositorySpec>
  templateDir: <string>
  backupExisting: <bool>
  excludeNamespaces: <NamespaceExcludeList>
  excludeBackupForNamespaces: <NamespaceExcludeList>
  autoMerge: <AutoMergeSpec>
  reconciliationInterval: <string>
  statusRetentionDays: <int>
  stalePRThreshold: <string>
  batchProcessing: <BatchProcessingSpec>
```

---

#### `networkPolicy.enabled` (optional)

**Type**: `bool`  
**Default**: `false`  
**Description**: Enables NetworkPolicy management via GitOps.

**Example**:
```yaml
networkPolicy:
  enabled: true
```

---

#### `networkPolicy.gitRepository` (optional)

**Type**: `GitRepositorySpec`  
**Description**: Git repository configuration for NetworkPolicy templates.

**Structure**:
```yaml
gitRepository:
  provider: <string>              # bitbucket, github, gitlab
  url: <string>                   # Repository URL
  baseBranch: <string>            # Base branch (main/master)
  clusterName: <string>           # Cluster name for paths
  credentialsSecretRef: <LdapSecretReference>
  apiBaseURL: <string>            # Optional: self-hosted Git
  gitTlsVerify: <*bool>           # Optional: TLS verification
```

**Example**:
```yaml
gitRepository:
  provider: github
  url: https://github.com/company/networkpolicies.git
  baseBranch: main
  clusterName: production-cluster
  credentialsSecretRef:
    name: git-credentials
    namespace: permission-binder-system
```

**Secret Required Keys**:
- `token`: Git provider access token
- `username`: (optional) Git username
- `email`: (optional) Git email for commits

---

#### `networkPolicy.templateDir` (optional)

**Type**: `string`  
**Description**: Directory path in Git repository containing NetworkPolicy templates.

**Example**:
```yaml
templateDir: networkpolicies/templates
```

**Behavior**:
- All `.yaml` files in this directory are treated as templates
- Templates are processed for each namespace
- Template variables: `{namespace}`, `{cluster}`

---

#### `networkPolicy.backupExisting` (optional)

**Type**: `bool`  
**Default**: `false`  
**Description**: Enables backup of existing NetworkPolicies from cluster to Git.

**Example**:
```yaml
backupExisting: true
```

**Behavior**:
- When enabled, existing policies are backed up before template application
- Variant B: Backup template-based policies
- Variant C: Backup non-template policies

---

#### `networkPolicy.excludeNamespaces` (optional)

**Type**: `NamespaceExcludeList`  
**Description**: Global exclude list that blocks ALL NetworkPolicy operations.

**Structure**:
```yaml
excludeNamespaces:
  patterns: <[]string>    # Regex patterns
  explicit: <[]string>    # Explicit namespace names
```

**Example**:
```yaml
excludeNamespaces:
  patterns:
    - "^kube-.*"
    - "^openshift-.*"
  explicit:
    - default
    - kube-system
```

**Behavior**:
- If namespace matches, operator will NOT create policies from templates
- Operator will NOT backup existing policies
- Complete exclusion from NetworkPolicy operations

---

#### `networkPolicy.excludeBackupForNamespaces` (optional)

**Type**: `NamespaceExcludeList`  
**Description**: Per-namespace exclude list for backup operations only.

**Example**:
```yaml
excludeBackupForNamespaces:
  explicit:
    - production
    - staging
```

**Behavior**:
- If namespace matches, operator will NOT backup existing policies (Variants B/C)
- Operator will STILL create policies from templates (Variant A)
- Partial exclusion (backup only)

---

#### `networkPolicy.autoMerge` (optional)

**Type**: `AutoMergeSpec`  
**Description**: Auto-merge configuration for PRs.

**Structure**:
```yaml
autoMerge:
  enabled: <bool>         # Default: true
  label: <string>         # Default: "auto-merge"
```

**Example**:
```yaml
autoMerge:
  enabled: true
  label: auto-merge
```

**Behavior**:
- When enabled, adds auto-merge label to PRs (Variant A only)
- Requires GitOps tool (ArgoCD, Flux) to respect the label
- Not applied to Variant B/C (backup PRs require review)

---

#### `networkPolicy.reconciliationInterval` (optional)

**Type**: `string`  
**Default**: `"1h"`  
**Description**: Interval for periodic reconciliation (drift detection).

**Example**:
```yaml
reconciliationInterval: "1h"   # Every hour
reconciliationInterval: "4h"   # Every 4 hours (less etcd load)
```

**Format**: Go duration string (e.g., `"1h"`, `"30m"`, `"4h"`)

**Behavior**:
- Periodic drift detection runs at this interval
- Compares Git state vs cluster state
- Detects manual changes to NetworkPolicies

---

#### `networkPolicy.statusRetentionDays` (optional)

**Type**: `int`  
**Default**: `30`  
**Description**: Number of days to retain status entries for removed namespaces.

**Example**:
```yaml
statusRetentionDays: 30
```

**Behavior**:
- Status entries for removed namespaces are kept for this duration
- After retention period, entries are cleaned up
- Useful for audit and troubleshooting

---

#### `networkPolicy.stalePRThreshold` (optional)

**Type**: `string`  
**Default**: `"30d"`  
**Description**: Threshold for marking PRs as stale.

**Example**:
```yaml
stalePRThreshold: "30d"
```

**Format**: Go duration string

**Behavior**:
- PRs older than this threshold are marked as `pr-stale`
- Useful for identifying PRs that need attention
- Status updated during periodic reconciliation

---

#### `networkPolicy.batchProcessing` (optional)

**Type**: `BatchProcessingSpec`  
**Description**: Batch processing configuration.

**Structure**:
```yaml
batchProcessing:
  batchSize: <int>                    # Default: 5
  sleepBetweenNamespaces: <string>    # Default: "3s"
  sleepBetweenBatches: <string>       # Default: "60s"
```

**Example**:
```yaml
batchProcessing:
  batchSize: 10
  sleepBetweenNamespaces: "5s"
  sleepBetweenBatches: "120s"
```

**Behavior**:
- Processes namespaces in batches to avoid overwhelming Git API
- Sleep between namespaces: Git API rate limiting
- Sleep between batches: GitOps sync delay (allows GitOps to apply changes)

---

## Status Fields

### `processedRoleBindings` (optional)

**Type**: `[]string`  
**Description**: List of successfully created RoleBindings.

**Format**: `"<namespace>/<rolebinding-name>"`

**Example**:
```yaml
processedRoleBindings:
  - project1/project1-engineer-rolebinding
  - project2/project2-viewer-rolebinding
```

---

### `processedServiceAccounts` (optional)

**Type**: `[]string`  
**Description**: List of successfully created ServiceAccounts.

**Format**: `"<namespace>/<serviceaccount-name>"`

**Example**:
```yaml
processedServiceAccounts:
  - project1/project1-sa-deploy
  - project2/project2-sa-runtime
```

---

### `lastProcessedConfigMapVersion` (optional)

**Type**: `string`  
**Description**: ResourceVersion of the last processed ConfigMap.

**Behavior**:
- Used to detect ConfigMap changes
- Reconciliation skipped if version unchanged
- Prevents unnecessary reconciliation loops

---

### `lastProcessedRoleMappingHash` (optional)

**Type**: `string`  
**Description**: Hash of the last processed role mapping.

**Behavior**:
- Used to detect role mapping changes
- Triggers full reconciliation when changed
- SHA256 hash of sorted role mapping

---

### `conditions` (optional)

**Type**: `[]metav1.Condition`  
**Description**: Latest observations of PermissionBinder state.

**Standard Conditions**:
- `Ready`: Overall readiness status
- `Reconciling`: Currently reconciling
- `Degraded`: Error state

**Example**:
```yaml
conditions:
  - type: Ready
    status: "True"
    reason: ReconciliationSucceeded
    message: "All resources reconciled successfully"
    lastTransitionTime: "2025-01-15T10:00:00Z"
```

---

### `networkPolicies` (optional)

**Type**: `[]NetworkPolicyStatus`  
**Description**: Status of NetworkPolicy management for each namespace.

**Structure**:
```yaml
networkPolicies:
  - namespace: <string>
    state: <string>
    prNumber: <*int>
    prBranch: <string>
    prUrl: <string>
    createdAt: <string>
    lastProcessedTemplateHash: <string>
    lastTemplateCheckTime: <*metav1.Time>
    errorMessage: <string>
    removedAt: <string>
```

**States**:
- `pr-created`: PR created, waiting for merge
- `pr-pending`: PR pending review
- `pr-merged`: PR merged, policy applied
- `pr-conflict`: PR has conflicts
- `pr-stale`: PR older than threshold
- `pr-removal`: PR created for removal
- `error`: Error state
- `removed`: Namespace removed from whitelist

---

### `lastNetworkPolicyReconciliation` (optional)

**Type**: `*metav1.Time`  
**Description**: Timestamp of last periodic NetworkPolicy reconciliation.

**Example**:
```yaml
lastNetworkPolicyReconciliation: "2025-01-15T10:00:00Z"
```

---

## Examples

### Minimal RBAC Configuration

```yaml
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: main-config
  namespace: permission-binder-system
spec:
  roleMapping:
    engineer: edit
    viewer: view
  prefixes:
    - COMPANY-K8S
  configMapName: ldap-whitelist
  configMapNamespace: permission-binder-system
```

### Full Configuration with NetworkPolicy

```yaml
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: production-config
  namespace: permission-binder-system
spec:
  # RBAC
  roleMapping:
    engineer: edit
    viewer: view
    admin: admin
  prefixes:
    - COMPANY-K8S
    - PROD-K8S
  excludeList:
    - COMPANY-K8S-test-exclude
  configMapName: ldap-whitelist
  configMapNamespace: permission-binder-system
  
  # LDAP
  createLdapGroups: true
  ldapSecretRef:
    name: ldap-credentials
    namespace: permission-binder-system
  ldapTlsVerify: true
  
  # ServiceAccounts
  serviceAccountMapping:
    deploy: edit
    runtime: view
  serviceAccountNamingPattern: "{namespace}-sa-{name}"
  
  # NetworkPolicy
  networkPolicy:
    enabled: true
    gitRepository:
      provider: github
      url: https://github.com/company/networkpolicies.git
      baseBranch: main
      clusterName: production-cluster
      credentialsSecretRef:
        name: git-credentials
        namespace: permission-binder-system
    templateDir: networkpolicies/templates
    backupExisting: true
    excludeNamespaces:
      patterns:
        - "^kube-.*"
        - "^openshift-.*"
      explicit:
        - default
        - kube-system
    excludeBackupForNamespaces:
      explicit:
        - production
    autoMerge:
      enabled: true
      label: auto-merge
    reconciliationInterval: "1h"
    statusRetentionDays: 30
    stalePRThreshold: "30d"
    batchProcessing:
      batchSize: 5
      sleepBetweenNamespaces: "3s"
      sleepBetweenBatches: "60s"
```

### Self-Hosted Git Server

```yaml
networkPolicy:
  enabled: true
  gitRepository:
    provider: bitbucket
    url: https://git.cembraintra.ch/scm/k8s/networkpolicies.git
    baseBranch: main
    clusterName: on-premise-cluster
    credentialsSecretRef:
      name: bitbucket-credentials
      namespace: permission-binder-system
    apiBaseURL: https://git.cembraintra.ch/rest/api/1.0
    gitTlsVerify: true
  templateDir: templates
```

---

## Field Reference

### Quick Reference Table

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `roleMapping` | `map[string]string` | ✅ | - | Role to ClusterRole mapping |
| `prefixes` | `[]string` | ✅ | - | LDAP DN prefixes |
| `excludeList` | `[]string` | ❌ | `[]` | CN values to exclude |
| `configMapName` | `string` | ✅ | - | ConfigMap name |
| `configMapNamespace` | `string` | ✅ | - | ConfigMap namespace |
| `createLdapGroups` | `bool` | ❌ | `false` | Enable LDAP group creation |
| `ldapSecretRef` | `LdapSecretReference` | ❌ | - | LDAP credentials secret |
| `ldapTlsVerify` | `*bool` | ❌ | `true` | LDAP TLS verification |
| `serviceAccountMapping` | `map[string]string` | ❌ | `{}` | SA name to role mapping |
| `serviceAccountNamingPattern` | `string` | ❌ | `"{namespace}-sa-{name}"` | SA naming pattern |
| `networkPolicy.enabled` | `bool` | ❌ | `false` | Enable NetworkPolicy management |
| `networkPolicy.gitRepository` | `GitRepositorySpec` | ❌ | - | Git repository config |
| `networkPolicy.templateDir` | `string` | ❌ | - | Template directory path |
| `networkPolicy.backupExisting` | `bool` | ❌ | `false` | Enable backup of existing policies |
| `networkPolicy.reconciliationInterval` | `string` | ❌ | `"1h"` | Periodic reconciliation interval |
| `networkPolicy.statusRetentionDays` | `int` | ❌ | `30` | Status retention period |
| `networkPolicy.stalePRThreshold` | `string` | ❌ | `"30d"` | Stale PR threshold |

---

**Last Updated**: 2025-01-15  
**Version**: v1.6.0-rc2

