# Permission Binder Operator - Sequence Diagrams

## Table of Contents

1. [Main Reconciliation Flow](#main-reconciliation-flow)
2. [RBAC RoleBinding Creation](#rbac-rolebinding-creation)
3. [NetworkPolicy Single Namespace Processing](#networkpolicy-single-namespace-processing)
4. [NetworkPolicy Batch Processing](#networkpolicy-batch-processing)
5. [NetworkPolicy Drift Detection](#networkpolicy-drift-detection)
6. [NetworkPolicy Cleanup Flow](#networkpolicy-cleanup-flow)
7. [ServiceAccount Creation](#serviceaccount-creation)
8. [LDAP Group Creation](#ldap-group-creation)
9. [Error Handling & Recovery](#error-handling--recovery)

## Main Reconciliation Flow

### Complete Reconciliation Cycle

```mermaid
sequenceDiagram
    participant K8S as Kubernetes API
    participant REC as Reconciler
    participant CM as ConfigMap
    participant RBAC as RBAC Module
    participant NP as NetworkPolicy Module
    participant STATUS as Status Manager
    participant METRICS as Metrics

    Note over K8S: PermissionBinder CR Created/Updated
    K8S->>REC: Reconcile Request
    REC->>K8S: Fetch PermissionBinder
    K8S-->>REC: PermissionBinder
    
    alt Deletion Timestamp Set
        REC->>REC: handleDeletion()
        REC->>K8S: Remove Finalizer
        REC-->>K8S: Return (deletion complete)
    end
    
    REC->>REC: Check RoleMapping Hash
    alt RoleMapping Changed
        REC->>REC: reconcileAllManagedResources()
        REC->>RBAC: Reconcile All RoleBindings
        RBAC-->>REC: Success
    end
    
    REC->>K8S: Re-fetch PermissionBinder
    K8S-->>REC: Latest PermissionBinder
    
    REC->>CM: Fetch ConfigMap
    CM-->>REC: ConfigMap Data
    
    REC->>REC: Compare ConfigMap Version
    alt ConfigMap Changed
        REC->>RBAC: processConfigMap()
        RBAC->>RBAC: Parse LDAP DNs
        RBAC->>RBAC: Process Entries
        RBAC-->>REC: ProcessedRoleBindings
        
        alt NetworkPolicy Enabled
            REC->>NP: ProcessNetworkPoliciesForNamespaces()
            NP-->>REC: Success
        end
        
        REC->>NP: ProcessRemovedNamespaces()
        NP-->>REC: Cleanup Complete
    else No Changes
        REC-->>K8S: Skip Reconciliation
    end
    
    REC->>STATUS: Update Status
    STATUS->>K8S: Update PermissionBinder Status
    REC->>METRICS: Update Metrics
    REC-->>K8S: Reconcile Complete
```

## RBAC RoleBinding Creation

### Single RoleBinding Creation Flow

```mermaid
sequenceDiagram
    participant REC as Reconciler
    participant PARSER as LDAP Parser
    participant VALID as ClusterRole Validator
    participant K8S as Kubernetes API
    participant METRICS as Metrics
    participant LOG as Logger

    REC->>PARSER: Parse LDAP DN Entry
    Note over PARSER: "CN=COMPANY-K8S-project1-engineer,OU=Kubernetes,DC=company,DC=com"
    PARSER->>PARSER: Extract Prefix
    PARSER->>PARSER: Extract Namespace
    PARSER->>PARSER: Extract Role
    PARSER-->>REC: Parsed: {namespace: "project1", role: "engineer"}

    REC->>REC: Check ExcludeList
    alt Excluded
        REC->>LOG: Log Exclusion
        REC-->>REC: Skip
    end

    REC->>REC: Map Role to ClusterRole
    Note over REC: "engineer" -> "edit"
    REC->>VALID: Validate ClusterRole Exists
    VALID->>K8S: Get ClusterRole("edit")
    
    alt ClusterRole Not Found
        K8S-->>VALID: NotFound Error
        VALID->>METRICS: Increment missing_clusterrole_total
        VALID->>LOG: Log Security Warning
        VALID-->>REC: Validation Failed
        REC-->>REC: Skip RoleBinding Creation
    else ClusterRole Found
        K8S-->>VALID: ClusterRole
        VALID-->>REC: Validation Success
        
        REC->>K8S: Get RoleBinding(namespace, name)
        alt RoleBinding Exists
            K8S-->>REC: Existing RoleBinding
            REC->>REC: Check if Managed
            alt Not Managed (Orphaned)
                REC->>REC: Adopt Resource
                REC->>K8S: Update RoleBinding (add annotations)
                K8S-->>REC: Updated
                REC->>METRICS: Increment adoption_events_total
            else Managed
                REC->>REC: Compare Desired vs Actual
                alt Needs Update
                    REC->>K8S: Update RoleBinding
                    K8S-->>REC: Updated
                else Up to Date
                    REC-->>REC: Skip
                end
            end
        else RoleBinding Not Found
            REC->>REC: Create RoleBinding
            REC->>K8S: Create RoleBinding
            K8S-->>REC: Created
            REC->>METRICS: Increment managed_rolebindings_total
        end
        
        REC->>LOG: Log Success (audit)
        REC->>METRICS: Increment success metrics
    end
```

## NetworkPolicy Single Namespace Processing

### Variant A: New File from Template

```mermaid
sequenceDiagram
    participant REC as Reconciler
    participant NP as NetworkPolicy Module
    participant GIT as Git Repository
    participant GITAPI as Git API
    participant K8S as Kubernetes API
    participant STATUS as Status Manager

    REC->>NP: ProcessNetworkPolicyForNamespace(namespace)
    NP->>NP: Get Git Credentials
    NP->>GIT: Clone Repository (shallow)
    GIT-->>NP: Repository Cloned
    
    NP->>GIT: Fetch Latest Changes
    GIT-->>NP: Updated
    
    NP->>GIT: Checkout Base Branch
    NP->>GIT: Reset to Origin
    
    NP->>GIT: List Templates
    GIT-->>NP: Template Files
    
    loop For each template
        NP->>NP: Process Template
        NP->>NP: Generate NetworkPolicy YAML
        NP->>NP: Generate File Path
        Note over NP: networkpolicies/{cluster}/{namespace}/{template}.yaml
        
        NP->>GIT: Check if File Exists
        alt File Not Exists
            NP->>GIT: Create New File
            NP->>GIT: Write NetworkPolicy YAML
            NP->>NP: Mark Variant A
        else File Exists
            NP->>NP: Check if from Template
            alt From Template (Variant B)
                NP->>K8S: Read Current Policy
                K8S-->>NP: NetworkPolicy
                NP->>GIT: Backup Existing
                NP->>GIT: Update from Template
            else Not from Template (Variant C)
                NP->>K8S: Read Current Policy
                K8S-->>NP: NetworkPolicy
                NP->>GIT: Backup Existing
                NP->>GIT: Create from Template
            end
        end
    end
    
    NP->>GIT: Generate Branch Name
    Note over NP: permission-binder-{namespace}-{timestamp}
    NP->>GIT: Create Branch
    NP->>GIT: Checkout Branch
    
    NP->>GIT: Add All Changes
    NP->>GIT: Commit Changes
    NP->>GIT: Push Branch
    
    NP->>GITAPI: Create Pull Request
    Note over GITAPI: Title, Description, Labels
    GITAPI-->>NP: PR Created (PR Number, URL)
    
    alt Auto-Merge Enabled (Variant A only)
        NP->>GITAPI: Add Auto-Merge Label
    end
    
    NP->>STATUS: Update Status
    Note over STATUS: State: "pr-created"<br/>PRNumber: 123<br/>PRURL: "https://..."
    STATUS->>K8S: Update PermissionBinder Status
    
    NP-->>REC: Success
```

## NetworkPolicy Batch Processing

### Event-Driven Batch Reconciliation

```mermaid
sequenceDiagram
    participant REC as Reconciler
    participant NP as NetworkPolicy Module
    participant BATCH as Batch Processor
    participant GIT as Git Repository
    participant GITAPI as Git API
    participant STATUS as Status Manager

    REC->>NP: ProcessNetworkPoliciesForNamespaces(namespaces)
    Note over NP: namespaces: ["ns1", "ns2", ..., "ns100"]
    
    NP->>NP: Chunk Namespaces (batchSize=5)
    Note over NP: Batches: [["ns1"..."ns5"], ["ns6"..."ns10"], ...]
    
    loop For each batch
        NP->>BATCH: Process Batch
        loop For each namespace in batch
            BATCH->>NP: ProcessNetworkPolicyForNamespace(namespace)
            NP->>GIT: Clone & Process
            NP->>GITAPI: Create PR
            GITAPI-->>NP: PR Created
            NP->>STATUS: Update Status
            
            alt Not Last in Batch
                NP->>NP: Sleep (3s - rate limiting)
            end
        end
        
        alt Not Last Batch
            NP->>NP: Sleep (60s - GitOps sync delay)
            Note over NP: Allows GitOps to apply changes
        end
    end
    
    NP-->>REC: Batch Processing Complete
```

## NetworkPolicy Drift Detection

### Periodic Drift Detection & Reconciliation

```mermaid
sequenceDiagram
    participant TIMER as Periodic Timer
    participant NP as NetworkPolicy Module
    participant STATUS as Status Manager
    participant GIT as Git Repository
    participant K8S as Kubernetes API
    participant DRIFT as Drift Detector

    TIMER->>NP: PeriodicNetworkPolicyReconciliation()
    Note over TIMER: Every 1h (configurable)
    
    NP->>STATUS: Get Managed Namespaces
    Note over STATUS: Filter: State == "pr-merged"
    STATUS-->>NP: Namespace List
    
    alt No Managed Namespaces
        NP->>STATUS: Update LastReconciliationTime
        NP-->>TIMER: Complete
    end
    
    NP->>NP: Chunk Namespaces (batchSize=20)
    
    loop For each batch
        loop For each namespace
            NP->>DRIFT: checkDriftForNamespace(namespace)
            
            DRIFT->>GIT: Clone Repository
            GIT-->>DRIFT: Repository Cloned
            
            DRIFT->>GIT: Read Expected Policy
            Note over GIT: From Git: networkpolicies/{cluster}/{namespace}/*.yaml
            GIT-->>DRIFT: Expected YAML
            
            DRIFT->>K8S: List NetworkPolicies(namespace)
            K8S-->>DRIFT: Actual Policies
            
            DRIFT->>DRIFT: Compare Expected vs Actual
            alt Drift Detected
                DRIFT->>DRIFT: Log Drift Warning
                DRIFT->>STATUS: Update Status (drift-detected)
                Note over STATUS: State: "drift-detected"<br/>ErrorMessage: "Policy mismatch"
            else No Drift
                DRIFT->>DRIFT: Continue
            end
        end
        
        alt Not Last Batch
            NP->>NP: Sleep (30s - etcd load)
        end
    end
    
    NP->>NP: checkTemplateChanges()
    NP->>GIT: Calculate Template Hash
    GIT-->>NP: Current Hash
    NP->>STATUS: Get LastProcessedTemplateHash
    STATUS-->>NP: Last Hash
    
    alt Template Hash Changed
        NP->>NP: Reprocess All Managed Namespaces
        Note over NP: Templates changed - need update
    end
    
    NP->>NP: checkStalePRs()
    NP->>STATUS: Get PRs (State: "pr-created", "pr-pending")
    STATUS-->>NP: PR List
    
    loop For each PR
        NP->>GITAPI: Check PR Age
        alt PR Older than Threshold (30d)
            NP->>STATUS: Update Status (pr-stale)
        end
    end
    
    NP->>STATUS: Update LastReconciliationTime
    STATUS->>K8S: Update PermissionBinder Status
    NP-->>TIMER: Complete
```

## NetworkPolicy Cleanup Flow

### Removed Namespace Cleanup

```mermaid
sequenceDiagram
    participant REC as Reconciler
    participant NP as NetworkPolicy Module
    participant STATUS as Status Manager
    participant GIT as Git Repository
    participant GITAPI as Git API
    participant K8S as Kubernetes API

    REC->>NP: ProcessRemovedNamespaces()
    
    NP->>STATUS: Get All NetworkPolicy Statuses
    STATUS-->>NP: Status List
    
    NP->>REC: Get Current Namespaces (from RoleBindings)
    REC-->>NP: Current Namespace List
    
    NP->>NP: Find Removed Namespaces
    Note over NP: Status exists but namespace not in current list
    
    loop For each removed namespace
        NP->>STATUS: Get Status
        alt State == "pr-merged"
            NP->>GIT: Clone Repository
            NP->>GIT: Create Removal Branch
            NP->>GIT: Delete NetworkPolicy Files
            Note over GIT: Remove: networkpolicies/{cluster}/{namespace}/
            NP->>GIT: Commit Removal
            NP->>GIT: Push Branch
            NP->>GITAPI: Create PR (Removal)
            GITAPI-->>NP: PR Created
            
            NP->>STATUS: Update Status
            Note over STATUS: State: "pr-removal"<br/>PRNumber: 456
        else State == "pr-created" or "pr-pending"
            NP->>GITAPI: Close PR
            GITAPI-->>NP: PR Closed
            NP->>STATUS: Update Status
            Note over STATUS: State: "removed"<br/>RemovedAt: timestamp
        end
        
        NP->>STATUS: Set RemovedAt Timestamp
    end
    
    NP->>NP: Cleanup Old Status Entries
    Note over NP: Remove entries older than StatusRetentionDays (30d)
    
    NP->>STATUS: Update Status
    STATUS->>K8S: Update PermissionBinder Status
    NP-->>REC: Cleanup Complete
```

## ServiceAccount Creation

### ServiceAccount with RoleBinding Flow

```mermaid
sequenceDiagram
    participant REC as Reconciler
    participant SA as ServiceAccount Module
    participant K8S as Kubernetes API
    participant METRICS as Metrics
    participant LOG as Logger

    REC->>SA: Process ServiceAccount Mapping
    Note over SA: Mapping: {"deploy": "edit", "runtime": "view"}
    
    loop For each namespace
        loop For each SA mapping
            SA->>SA: Generate ServiceAccount Name
            Note over SA: Pattern: {namespace}-sa-{name}<br/>Example: "my-app-sa-deploy"
            
            SA->>K8S: Get ServiceAccount(namespace, name)
            alt ServiceAccount Not Found
                K8S-->>SA: NotFound
                SA->>SA: Create ServiceAccount
                SA->>K8S: Create ServiceAccount
                K8S-->>SA: Created
                SA->>METRICS: Increment service_accounts_created_total
            else ServiceAccount Exists
                K8S-->>SA: ServiceAccount
                SA->>SA: Check if Managed
                alt Not Managed
                    SA->>SA: Adopt Resource
                    SA->>K8S: Update ServiceAccount
                else Managed
                    SA-->>SA: Skip (already exists)
                end
            end
            
            SA->>SA: Generate RoleBinding Name
            Note over SA: Pattern: {sa-name}-rolebinding
            SA->>K8S: Get RoleBinding(namespace, name)
            alt RoleBinding Not Found
                SA->>SA: Create RoleBinding
                SA->>K8S: Create RoleBinding
                K8S-->>SA: Created
            else RoleBinding Exists
                SA->>SA: Update RoleBinding (if needed)
                SA->>K8S: Update RoleBinding
            end
            
            SA->>LOG: Log Success (audit)
            SA->>METRICS: Update Metrics
        end
    end
    
    SA->>REC: Update Status
    Note over REC: ProcessedServiceAccounts: ["ns1/sa1", "ns2/sa2", ...]
    SA-->>REC: Success
```

## LDAP Group Creation

### Automatic LDAP Group Creation Flow

```mermaid
sequenceDiagram
    participant REC as Reconciler
    participant LDAP as LDAP Module
    participant AD as Active Directory
    participant K8S as Kubernetes API
    participant METRICS as Metrics

    REC->>REC: Check CreateLdapGroups Flag
    alt CreateLdapGroups == true
        REC->>LDAP: Create LDAP Group for Namespace
        
        LDAP->>K8S: Get LDAP Secret
        K8S-->>LDAP: Secret (credentials)
        
        LDAP->>LDAP: Parse LDAP DN
        Note over LDAP: Extract: CN, OU, DC
        
        LDAP->>AD: Connect LDAPS
        AD-->>LDAP: Connection Established
        
        LDAP->>AD: Check if Group Exists
        AD-->>LDAP: Group Status
        
        alt Group Not Exists
            LDAP->>AD: Create Group
            Note over AD: CN={namespace}-k8s-group,OU=Kubernetes,DC=company,DC=com
            AD-->>LDAP: Group Created
            LDAP->>METRICS: Increment ldap_group_operations_total<br/>(operation: "created")
        else Group Exists
            LDAP->>METRICS: Increment ldap_group_operations_total<br/>(operation: "exists")
            LDAP-->>REC: Group Already Exists
        end
        
        LDAP->>AD: Close Connection
        LDAP-->>REC: Success
    end
```

## Error Handling & Recovery

### Error Recovery & Retry Flow

```mermaid
sequenceDiagram
    participant REC as Reconciler
    participant OP as Operation
    participant K8S as Kubernetes API
    participant STATUS as Status Manager
    participant METRICS as Metrics
    participant LOG as Logger

    REC->>OP: Execute Operation
    
    alt Operation Success
        OP-->>REC: Success
        REC->>STATUS: Update Status (Success)
        REC->>METRICS: Increment Success Metrics
    else Temporary Error (Retryable)
        OP-->>REC: Temporary Error
        Note over REC: Examples: Network timeout, API rate limit
        
        REC->>LOG: Log Error (Warning)
        REC->>METRICS: Increment Error Metrics
        REC->>REC: Calculate Requeue Time
        Note over REC: Exponential backoff
        
        REC-->>K8S: Requeue After (backoff)
        Note over K8S: Retry later
    else Permanent Error (Non-Retryable)
        OP-->>REC: Permanent Error
        Note over REC: Examples: Invalid config, missing ClusterRole
        
        REC->>LOG: Log Error (Error)
        REC->>METRICS: Increment Error Metrics
        REC->>STATUS: Update Status (Error Condition)
        STATUS->>K8S: Update PermissionBinder Status
        
        REC-->>K8S: Return Error (no requeue)
        Note over K8S: Manual intervention required
    else Partial Failure
        OP-->>REC: Partial Results
        Note over REC: Some namespaces succeeded, some failed
        
        REC->>LOG: Log Partial Success
        REC->>STATUS: Update Status (Partial)
        REC->>METRICS: Update Metrics (mixed)
        
        REC->>REC: Continue with Next Operation
        Note over REC: Don't fail entire reconciliation
    end
```

### Orphaned Resource Adoption

```mermaid
sequenceDiagram
    participant REC as Reconciler
    participant K8S as Kubernetes API
    participant RB as RoleBinding
    participant METRICS as Metrics
    participant LOG as Logger

    REC->>K8S: List RoleBindings
    K8S-->>REC: RoleBinding List
    
    loop For each RoleBinding
        REC->>REC: Check if Managed
        alt Has Managed Annotation
            REC-->>REC: Skip (already managed)
        else No Managed Annotation
            REC->>REC: Check if Should Be Managed
            Note over REC: Matches namespace pattern,<br/>has expected subjects
            
            alt Should Be Managed
                REC->>RB: Add Managed Annotations
                Note over RB: permission-binder.io/managed-by<br/>permission-binder.io/created-at
                
                REC->>K8S: Update RoleBinding
                K8S-->>RB: Updated
                RB-->>REC: Success
                
                REC->>METRICS: Increment adoption_events_total
                REC->>LOG: Log Adoption (audit)
                Note over LOG: "Adopted orphaned RoleBinding"
            else Should Not Be Managed
                REC-->>REC: Skip (user-created)
            end
        end
    end
```

---

**Last Updated**: 2025-11-14  
**Version**: v1.6.5

