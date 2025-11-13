# Permission Binder Operator - Architecture Documentation

## Table of Contents

1. [System Architecture](#system-architecture)
2. [Component Architecture](#component-architecture)
3. [Data Flow](#data-flow)
4. [Deployment Architecture](#deployment-architecture)
5. [Security Architecture](#security-architecture)

## System Architecture

### High-Level Overview

```mermaid
graph TB
    subgraph "Kubernetes Cluster"
        subgraph "Operator Namespace"
            OP[Permission Binder Operator]
            CRD[PermissionBinder CRD]
        end
        
        subgraph "Application Namespaces"
            RB1[RoleBinding]
            RB2[RoleBinding]
            NP1[NetworkPolicy]
            NP2[NetworkPolicy]
        end
        
        subgraph "Config Namespace"
            CM[ConfigMap<br/>LDAP Whitelist]
        end
        
        subgraph "System"
            SA[ServiceAccounts]
            CR[ClusterRoles]
        end
    end
    
    subgraph "External Systems"
        LDAP[LDAP Server<br/>Active Directory]
        GIT[Git Repository<br/>GitHub/GitLab/Bitbucket]
    end
    
    subgraph "Monitoring"
        PROM[Prometheus]
        LOKI[Loki]
    end
    
    CRD -->|Reconcile| OP
    CM -->|Watch| OP
    OP -->|Create/Update| RB1
    OP -->|Create/Update| RB2
    OP -->|Create/Update| NP1
    OP -->|Create/Update| NP2
    OP -->|Create| SA
    OP -->|Read| CR
    OP -->|Query| LDAP
    OP -->|Clone/Commit/PR| GIT
    OP -->|Metrics| PROM
    OP -->|Logs| LOKI
```

### Component Interaction

```mermaid
graph LR
    subgraph "Controller Runtime"
        REC[Reconciler]
        WATCH[Watchers]
        QUEUE[Work Queue]
    end
    
    subgraph "RBAC Module"
        PARSER[LDAP Parser]
        RBAC[RoleBinding Manager]
        VALID[ClusterRole Validator]
    end
    
    subgraph "NetworkPolicy Module"
        GITOPS[GitOps Manager]
        TEMPLATE[Template Processor]
        DRIFT[Drift Detector]
    end
    
    subgraph "Infrastructure"
        METRICS[Metrics]
        LOGGER[Logger]
        CLIENT[K8s Client]
    end
    
    REC --> WATCH
    WATCH --> QUEUE
    QUEUE --> REC
    REC --> PARSER
    REC --> RBAC
    REC --> GITOPS
    PARSER --> VALID
    RBAC --> CLIENT
    GITOPS --> TEMPLATE
    GITOPS --> DRIFT
    REC --> METRICS
    REC --> LOGGER
    REC --> CLIENT
```

## Component Architecture

### PermissionBinderReconciler

```mermaid
classDiagram
    class PermissionBinderReconciler {
        -Client client.Client
        -Scheme *runtime.Scheme
        -Metrics *Metrics
        -DebugMode bool
        +Reconcile(ctx, req) Result
        -processConfigMap(ctx, pb, cm) Result
        -reconcileAllManagedResources(ctx, pb) error
        -handleDeletion(ctx, pb) error
    }
    
    class RBACModule {
        +processRoleBindings(ctx, pb, entries) Result
        +createOrUpdateRoleBinding(ctx, ns, group, role) error
        +validateClusterRole(ctx, role) error
        +detectDrift(ctx, rb) error
    }
    
    class NetworkPolicyModule {
        +ProcessNetworkPoliciesForNamespaces(ctx, r, pb, ns) error
        +ProcessNetworkPolicyForNamespace(ctx, r, pb, ns) error
        +ProcessRemovedNamespaces(ctx, r, pb) error
        +PeriodicNetworkPolicyReconciliation(ctx, r, pb) error
    }
    
    class GitOperations {
        +Clone(ctx, url, branch) error
        +CommitAndPush(ctx, msg) error
        +CreatePR(ctx, branch, title) error
        +MergePR(ctx, prNumber) error
    }
    
    PermissionBinderReconciler --> RBACModule
    PermissionBinderReconciler --> NetworkPolicyModule
    NetworkPolicyModule --> GitOperations
```

### NetworkPolicy Module Structure

```mermaid
graph TB
    subgraph "NetworkPolicy Package"
        MAIN[network_policy_reconciliation.go<br/>Main Entry Point]
        
        subgraph "Reconciliation"
            SINGLE[reconciliation_single.go<br/>Single Namespace]
            BATCH[reconciliation_batch.go<br/>Batch Processing]
            PERIODIC[reconciliation_periodic.go<br/>Periodic Sync]
            CLEANUP[reconciliation_cleanup.go<br/>Removed Namespaces]
            VALID[reconciliation_validation.go<br/>Multi-CR Check]
        end
        
        subgraph "Business Logic"
            TEMPLATE[network_policy_template_simple.go<br/>Template Processing]
            BACKUP[network_policy_backup_simple.go<br/>Backup Logic]
            DRIFT[network_policy_drift.go<br/>Drift Detection]
            KUSTOM[network_policy_kustomization_simple.go<br/>Kustomization]
        end
        
        subgraph "Git Operations"
            GIT_API[git_api.go<br/>REST API]
            GIT_CLI[git_cli.go<br/>Git CLI]
            GIT_CRED[git_credentials.go<br/>Credentials]
            GIT_FILE[git_file_operations.go<br/>File Ops]
        end
        
        subgraph "Helpers"
            HELPER[network_policy_helper.go<br/>Helper Functions]
            UTILS[network_policy_utils.go<br/>Utilities]
            STATUS[network_policy_status.go<br/>Status Updates]
        end
    end
    
    MAIN --> SINGLE
    MAIN --> BATCH
    MAIN --> PERIODIC
    MAIN --> CLEANUP
    MAIN --> VALID
    
    SINGLE --> TEMPLATE
    SINGLE --> BACKUP
    SINGLE --> GIT_API
    SINGLE --> GIT_CLI
    
    PERIODIC --> DRIFT
    PERIODIC --> TEMPLATE
    
    CLEANUP --> GIT_API
    
    TEMPLATE --> KUSTOM
    BACKUP --> GIT_FILE
    
    SINGLE --> HELPER
    BATCH --> HELPER
    PERIODIC --> HELPER
    
    HELPER --> UTILS
    HELPER --> STATUS
```

## Data Flow

### RBAC Reconciliation Flow

```mermaid
sequenceDiagram
    participant CM as ConfigMap
    participant REC as Reconciler
    participant PARSER as LDAP Parser
    participant VALID as ClusterRole Validator
    participant K8S as Kubernetes API
    participant METRICS as Prometheus
    
    CM->>REC: ConfigMap Changed
    REC->>REC: Fetch PermissionBinder
    REC->>CM: Read ConfigMap Data
    REC->>PARSER: Parse LDAP DNs
    loop For each entry
        PARSER->>PARSER: Extract namespace & role
        PARSER->>VALID: Validate ClusterRole exists
        VALID->>K8S: Check ClusterRole
        alt ClusterRole exists
            VALID-->>PARSER: Valid
            PARSER->>K8S: Create/Update RoleBinding
            K8S-->>PARSER: Success
            PARSER->>METRICS: Increment success
        else ClusterRole missing
            VALID-->>PARSER: Invalid
            PARSER->>METRICS: Increment missing_clusterrole
            PARSER->>REC: Log warning
        end
    end
    REC->>REC: Update Status
    REC->>K8S: Update PermissionBinder Status
```

### NetworkPolicy GitOps Flow

```mermaid
sequenceDiagram
    participant REC as Reconciler
    participant NP as NetworkPolicy Module
    participant GIT as Git Repository
    participant GITAPI as Git API<br/>GitHub/GitLab/Bitbucket
    participant ARGO as ArgoCD<br/>GitOps Tool
    participant K8S as Kubernetes API
    
    REC->>NP: ProcessNetworkPolicyForNamespace
    NP->>GIT: Clone Repository
    GIT-->>NP: Repository Cloned
    
    NP->>NP: Load Templates
    NP->>NP: Process Template for Namespace
    NP->>NP: Generate NetworkPolicy YAML
    
    alt Variant A: New File
        NP->>GIT: Create New File
    else Variant B: Backup Existing
        NP->>K8S: Read Existing Policy
        NP->>GIT: Backup to Git
        NP->>GIT: Update from Template
    else Variant C: Backup Non-Template
        NP->>K8S: Read Existing Policy
        NP->>GIT: Backup to Git
        NP->>GIT: Create from Template
    end
    
    NP->>GIT: Commit Changes
    NP->>GIT: Push Branch
    NP->>GITAPI: Create Pull Request
    GITAPI-->>NP: PR Created
    
    NP->>NP: Update Status (pr-created)
    NP->>REC: Return Success
    
    Note over GITAPI,ARGO: Manual Review & Approval
    GITAPI->>ARGO: PR Merged
    ARGO->>K8S: Apply NetworkPolicy
    K8S-->>ARGO: Policy Applied
    
    NP->>NP: Periodic Check
    NP->>GITAPI: Check PR Status
    GITAPI-->>NP: PR Merged
    NP->>NP: Update Status (pr-merged)
```

### Periodic Drift Detection Flow

```mermaid
sequenceDiagram
    participant TIMER as Periodic Timer
    participant NP as NetworkPolicy Module
    participant GIT as Git Repository
    participant K8S as Kubernetes API
    participant STATUS as Status Manager
    
    TIMER->>NP: PeriodicNetworkPolicyReconciliation
    NP->>STATUS: Get Managed Namespaces<br/>State: pr-merged
    STATUS-->>NP: Namespace List
    
    loop For each namespace (batched)
        NP->>GIT: Clone Repository
        GIT-->>NP: Repository Cloned
        NP->>GIT: Read Expected Policy
        NP->>K8S: Read Actual Policy
        NP->>NP: Compare (drift detection)
        
        alt Drift Detected
            NP->>NP: Log Drift Warning
            NP->>STATUS: Update Status (drift-detected)
        else No Drift
            NP->>NP: Continue
        end
    end
    
    NP->>NP: Check Template Changes
    NP->>GIT: Compare Template Hash
    alt Templates Changed
        NP->>NP: Reprocess All Namespaces
    end
    
    NP->>STATUS: Update LastReconciliationTime
```

## Deployment Architecture

### Operator Deployment

```mermaid
graph TB
    subgraph "Kubernetes Cluster"
        subgraph "permissions-binder-operator namespace"
            DEPLOY[Deployment<br/>operator-controller-manager]
            SA[ServiceAccount<br/>operator-controller-manager]
            RB[RoleBinding<br/>operator-rolebinding]
            CR[ClusterRole<br/>operator-manager-role]
            SVC[Service<br/>operator-controller-manager-metrics-service]
        end
        
        subgraph "CRD Resources"
            CRD[PermissionBinder CRD]
            INST[PermissionBinder Instance]
        end
        
        subgraph "Config Namespace"
            CM[ConfigMap<br/>LDAP Whitelist]
            SECRET[Secret<br/>LDAP Credentials]
        end
    end
    
    subgraph "External"
        REGISTRY[Docker Registry<br/>lukaszbielinski/permission-binder-operator]
    end
    
    REGISTRY -->|Pull Image| DEPLOY
    DEPLOY --> SA
    SA --> RB
    RB --> CR
    DEPLOY -->|Watch| CRD
    DEPLOY -->|Read| CM
    DEPLOY -->|Read| SECRET
    DEPLOY -->|Create/Update| INST
    DEPLOY -->|Metrics| SVC
```

### Multi-Architecture Support

```mermaid
graph LR
    subgraph "Build Pipeline"
        SOURCE[Source Code]
        BUILD[Multi-Arch Build]
        AMD64[AMD64 Image]
        ARM64[ARM64 Image]
    end
    
    subgraph "Registry"
        MANIFEST[Multi-Arch Manifest]
    end
    
    subgraph "Kubernetes Cluster"
        NODE1[AMD64 Node]
        NODE2[ARM64 Node]
    end
    
    SOURCE --> BUILD
    BUILD --> AMD64
    BUILD --> ARM64
    AMD64 --> MANIFEST
    ARM64 --> MANIFEST
    MANIFEST -->|Pull| NODE1
    MANIFEST -->|Pull| NODE2
```

## Security Architecture

### Authentication & Authorization

```mermaid
graph TB
    subgraph "Operator Pod"
        OP[Operator Process]
        SA[ServiceAccount]
    end
    
    subgraph "Kubernetes API"
        RBAC[RBAC System]
        CR[ClusterRole]
        RB[RoleBinding]
    end
    
    subgraph "External Auth"
        LDAP[LDAP Server]
        GIT[Git Provider]
    end
    
    OP -->|Uses| SA
    SA -->|Bound to| RB
    RB -->|References| CR
    CR -->|Grants| RBAC
    RBAC -->|Authorizes| OP
    
    OP -->|LDAPS| LDAP
    OP -->|Token| GIT
```

### Secret Management

```mermaid
graph LR
    subgraph "Kubernetes Secrets"
        LDAP_SEC[LDAP Secret<br/>domain_server<br/>domain_username<br/>domain_password]
        GIT_SEC[Git Secret<br/>token<br/>username<br/>email]
    end
    
    subgraph "Operator"
        OP[Reconciler]
        CRED[Credential Manager]
    end
    
    subgraph "External"
        LDAP[LDAP Server]
        GIT[Git Repository]
    end
    
    LDAP_SEC -->|Read| OP
    GIT_SEC -->|Read| OP
    OP -->|Decrypt| CRED
    CRED -->|Authenticate| LDAP
    CRED -->|Authenticate| GIT
```

### Audit Trail

```mermaid
graph TB
    subgraph "Operator"
        OP[Reconciler]
        LOG[Structured Logger]
    end
    
    subgraph "Log Aggregation"
        LOKI[Loki]
        SIEM[SIEM System]
    end
    
    subgraph "Metrics"
        PROM[Prometheus]
        ALERTS[AlertManager]
    end
    
    OP -->|JSON Logs| LOG
    LOG -->|Audit Events| LOKI
    LOKI -->|Forward| SIEM
    
    OP -->|Metrics| PROM
    PROM -->|Alerts| ALERTS
    
    LOG -.->|RBAC Changes| SIEM
    LOG -.->|NetworkPolicy Changes| SIEM
    PROM -.->|Security Events| ALERTS
```

## Key Design Decisions

### 1. SAFE MODE (Orphaning vs Deletion)
- **Decision**: Resources are orphaned, never deleted
- **Rationale**: Zero data loss in production, automatic recovery
- **Implementation**: Annotations mark resources as orphaned

### 2. GitOps for NetworkPolicy
- **Decision**: NetworkPolicy changes via Pull Requests
- **Rationale**: Change control, approval workflow, audit trail
- **Implementation**: Operator creates PRs, manual merge triggers GitOps sync

### 3. Batch Processing
- **Decision**: Process namespaces in batches with delays
- **Rationale**: Rate limiting, GitOps sync time, etcd load
- **Implementation**: Configurable batch size and sleep intervals

### 4. Drift Detection
- **Decision**: Periodic reconciliation detects configuration drift
- **Rationale**: Detect manual changes, ensure compliance
- **Implementation**: Compare Git state vs cluster state

### 5. Multi-Architecture Support
- **Decision**: Support both AMD64 and ARM64
- **Rationale**: Edge computing, mixed clusters
- **Implementation**: Multi-arch Docker builds with manifest lists

---

**Last Updated**: 2025-01-15  
**Version**: v1.6.0-rc2

