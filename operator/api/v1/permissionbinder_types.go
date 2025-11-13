/*
Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// EDIT THIS FILE!  THIS IS SCAFFOLDING FOR YOU TO OWN!
// NOTE: json tags are required.  Any new fields you add must have json tags for the fields to be serialized.

// LdapSecretReference contains reference to a Secret with LDAP credentials
type LdapSecretReference struct {
	// Name of the Secret containing LDAP credentials
	// +kubebuilder:validation:Required
	Name string `json:"name"`

	// Namespace of the Secret containing LDAP credentials
	// +kubebuilder:validation:Required
	Namespace string `json:"namespace"`
}

// ServiceAccountRoleRef defines the role reference for a ServiceAccount
type ServiceAccountRoleRef struct {
	// Kind of the role (ClusterRole or Role)
	// +kubebuilder:validation:Enum=ClusterRole;Role
	// +kubebuilder:default=ClusterRole
	Kind string `json:"kind,omitempty"`

	// Name of the ClusterRole or Role
	// +kubebuilder:validation:Required
	Name string `json:"name"`
}

// PermissionBinderSpec defines the desired state of PermissionBinder
type PermissionBinderSpec struct {
	// RoleMapping defines mapping of role names to existing ClusterRoles
	// +kubebuilder:validation:Required
	RoleMapping map[string]string `json:"roleMapping"`

	// Prefixes used to identify permission strings (e.g., ["COMPANY-K8S", "MT-K8S"])
	// Supports multiple prefixes for multi-tenant scenarios
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinItems=1
	Prefixes []string `json:"prefixes"`

	// ExcludeList contains CN values to exclude from processing
	// +kubebuilder:validation:Optional
	ExcludeList []string `json:"excludeList,omitempty"`

	// ConfigMapName is the name of the ConfigMap to watch for changes
	// +kubebuilder:validation:Required
	ConfigMapName string `json:"configMapName"`

	// ConfigMapNamespace is the namespace where the ConfigMap is located
	// +kubebuilder:validation:Required
	ConfigMapNamespace string `json:"configMapNamespace"`

	// CreateLdapGroups enables automatic LDAP group creation for namespaces
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=false
	CreateLdapGroups bool `json:"createLdapGroups,omitempty"`

	// LdapSecretRef references a Secret containing LDAP connection credentials
	// Required keys: domain_server, domain_username, domain_password
	// +kubebuilder:validation:Optional
	LdapSecretRef *LdapSecretReference `json:"ldapSecretRef,omitempty"`

	// LdapTlsVerify enables TLS certificate verification for LDAPS connections
	// Set to false to skip certificate verification (insecure, for testing only)
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=true
	LdapTlsVerify *bool `json:"ldapTlsVerify,omitempty"`

	// ServiceAccountMapping defines mapping of service account names to roles
	// Creates ServiceAccounts with pattern defined by serviceAccountNamingPattern
	// Example: "deploy: edit" creates SA with ClusterRole "edit"
	// Default pattern: {namespace}-sa-{name}
	// +kubebuilder:validation:Optional
	ServiceAccountMapping map[string]string `json:"serviceAccountMapping,omitempty"`

	// ServiceAccountNamingPattern defines the naming pattern for ServiceAccounts
	// Available variables: {namespace}, {name}
	// Default: {namespace}-sa-{name}
	// Examples:
	//   - {namespace}-sa-{name}      -> my-app-sa-deploy
	//   - sa-{namespace}-{name}      -> sa-my-app-deploy
	//   - {name}-{namespace}         -> deploy-my-app
	//   - {namespace}-{name}         -> my-app-deploy
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="{namespace}-sa-{name}"
	ServiceAccountNamingPattern string `json:"serviceAccountNamingPattern,omitempty"`

	// NetworkPolicy configuration for GitOps-based Network Policy management
	// +kubebuilder:validation:Optional
	NetworkPolicy *NetworkPolicySpec `json:"networkPolicy,omitempty"`
}

// NetworkPolicySpec defines the Network Policy management configuration
type NetworkPolicySpec struct {
	// Enabled enables Network Policy management via GitOps
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=false
	Enabled bool `json:"enabled,omitempty"`

	// GitRepository configuration for GitOps repository
	// +kubebuilder:validation:Optional
	GitRepository *GitRepositorySpec `json:"gitRepository,omitempty"`

	// TemplateDir is the directory path in Git repository containing Network Policy templates
	// All .yaml files in this directory are treated as templates
	// Example: "networkpolicies/templates"
	// +kubebuilder:validation:Optional
	TemplateDir string `json:"templateDir,omitempty"`

	// BackupExisting enables backup of existing NetworkPolicies from cluster to Git
	// Default: false (safe - does not conflict with other GitOps tools)
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=false
	BackupExisting bool `json:"backupExisting,omitempty"`

	// ExcludeNamespaces is a global exclude list that blocks ALL NetworkPolicy operations
	// If a namespace is in this list, operator will NOT create policies from templates
	// and will NOT backup existing policies
	// +kubebuilder:validation:Optional
	ExcludeNamespaces *NamespaceExcludeList `json:"excludeNamespaces,omitempty"`

	// ExcludeBackupForNamespaces is a per-namespace exclude list for backup operations only
	// If a namespace is in this list, operator will NOT backup existing policies (Variants B/C)
	// but will STILL create policies from templates (Variant A)
	// +kubebuilder:validation:Optional
	ExcludeBackupForNamespaces *NamespaceExcludeList `json:"excludeBackupForNamespaces,omitempty"`

	// AutoMerge configuration for auto-merge labels
	// +kubebuilder:validation:Optional
	AutoMerge *AutoMergeSpec `json:"autoMerge,omitempty"`

	// ReconciliationInterval is the interval for periodic reconciliation (drift detection)
	// Default: "1h" (can be set to "4h" to avoid overwhelming etcd)
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="1h"
	ReconciliationInterval string `json:"reconciliationInterval,omitempty"`

	// StatusRetentionDays is the number of days to retain status entries for removed namespaces
	// Default: 30 days
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=30
	StatusRetentionDays int `json:"statusRetentionDays,omitempty"`

	// StalePRThreshold is the threshold for marking PRs as stale (duration string)
	// Default: "30d" (30 days)
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="30d"
	StalePRThreshold string `json:"stalePRThreshold,omitempty"`

	// BatchProcessing configuration for batch processing of namespaces
	// +kubebuilder:validation:Optional
	BatchProcessing *BatchProcessingSpec `json:"batchProcessing,omitempty"`
}

// GitRepositorySpec defines Git repository configuration
type GitRepositorySpec struct {
	// Provider is the Git provider (bitbucket, github, gitlab)
	// Optional for public providers (auto-detected from URL)
	// Required for self-hosted Git servers (e.g., git.cembraintra.ch)
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Enum=bitbucket;github;gitlab
	Provider string `json:"provider,omitempty"`

	// URL is the Git repository URL (HTTPS)
	// +kubebuilder:validation:Required
	URL string `json:"url"`

	// BaseBranch is the base branch for PRs (typically "main" or "master")
	// +kubebuilder:validation:Required
	BaseBranch string `json:"baseBranch"`

	// ClusterName is the cluster name used in Git repository paths
	// Example: "DEV-cluster" -> networkpolicies/DEV-cluster/...
	// +kubebuilder:validation:Required
	ClusterName string `json:"clusterName"`

	// CredentialsSecretRef references a Secret containing Git credentials
	// Required keys: token (and optionally username, email)
	// +kubebuilder:validation:Required
	CredentialsSecretRef *LdapSecretReference `json:"credentialsSecretRef"`

	// APIBaseURL is the API base URL for self-hosted Git servers
	// Optional - auto-detected from URL if not provided
	// Examples:
	//   - Bitbucket: https://git.cembraintra.ch/rest/api/1.0
	//   - GitHub: https://git.cembraintra.ch/api/v3
	//   - GitLab: https://git.cembraintra.ch/api/v4
	// +kubebuilder:validation:Optional
	APIBaseURL string `json:"apiBaseURL,omitempty"`

	// GitTlsVerify enables TLS certificate verification for Git HTTPS connections
	// Set to false to skip certificate verification (insecure, for self-signed certs only)
	// Default: true (secure)
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=true
	GitTlsVerify *bool `json:"gitTlsVerify,omitempty"`
}

// AutoMergeSpec defines auto-merge configuration
type AutoMergeSpec struct {
	// Enabled enables auto-merge labels
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=true
	Enabled bool `json:"enabled,omitempty"`

	// Label is the label added to PRs for auto-merge
	// Only added for Variant A (new file from template)
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="auto-merge"
	Label string `json:"label,omitempty"`
}

// NamespaceExcludeList defines patterns and explicit names for excluding namespaces
type NamespaceExcludeList struct {
	// Patterns are regex patterns for excluding namespaces
	// Example: ["^openshift-.*", "^ocp-.*", "^kube-.*"]
	// +kubebuilder:validation:Optional
	Patterns []string `json:"patterns,omitempty"`

	// Explicit is a list of explicit namespace names to exclude
	// Example: ["default", "kube-system"]
	// +kubebuilder:validation:Optional
	Explicit []string `json:"explicit,omitempty"`
}

// BatchProcessingSpec defines batch processing configuration
type BatchProcessingSpec struct {
	// BatchSize is the number of namespaces processed in each batch
	// Default: 5
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=5
	BatchSize int `json:"batchSize,omitempty"`

	// SleepBetweenNamespaces is the sleep duration between namespaces within a batch
	// Default: "3s" (Git API rate limiting)
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="3s"
	SleepBetweenNamespaces string `json:"sleepBetweenNamespaces,omitempty"`

	// SleepBetweenBatches is the sleep duration between batches
	// Default: "60s" (GitOps sync delay - allows GitOps to apply changes)
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="60s"
	SleepBetweenBatches string `json:"sleepBetweenBatches,omitempty"`
}

// PermissionBinderStatus defines the observed state of PermissionBinder
type PermissionBinderStatus struct {
	// ProcessedRoleBindings contains the list of successfully created RoleBindings
	ProcessedRoleBindings []string `json:"processedRoleBindings,omitempty"`

	// ProcessedServiceAccounts contains the list of successfully created ServiceAccounts
	ProcessedServiceAccounts []string `json:"processedServiceAccounts,omitempty"`

	// LastProcessedConfigMapVersion tracks the last processed ConfigMap version
	LastProcessedConfigMapVersion string `json:"lastProcessedConfigMapVersion,omitempty"`

	// LastProcessedRoleMappingHash tracks the hash of the last processed role mapping
	// This is used to detect when role mapping changes and trigger reconciliation
	LastProcessedRoleMappingHash string `json:"lastProcessedRoleMappingHash,omitempty"`

	// Conditions represent the latest available observations of the PermissionBinder's state
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// NetworkPolicies contains the status of Network Policy management for each namespace
	// +kubebuilder:validation:Optional
	NetworkPolicies []NetworkPolicyStatus `json:"networkPolicies,omitempty"`

	// LastNetworkPolicyReconciliation tracks the last time periodic NetworkPolicy reconciliation ran
	// +kubebuilder:validation:Optional
	LastNetworkPolicyReconciliation *metav1.Time `json:"lastNetworkPolicyReconciliation,omitempty"`
}

// NetworkPolicyStatus tracks the status of Network Policy management for a namespace
type NetworkPolicyStatus struct {
	// Namespace is the namespace name
	// +kubebuilder:validation:Required
	Namespace string `json:"namespace"`

	// State is the current state of Network Policy management
	// Possible values: "pr-created", "pr-pending", "pr-merged", "pr-conflict", "pr-stale", "pr-removal", "error", "removed"
	// +kubebuilder:validation:Required
	State string `json:"state"`

	// PRNumber is the Pull Request number (if applicable)
	// +kubebuilder:validation:Optional
	PRNumber *int `json:"prNumber,omitempty"`

	// PRBranch is the branch name for the PR
	// +kubebuilder:validation:Optional
	PRBranch string `json:"prBranch,omitempty"`

	// PRURL is the URL to the Pull Request
	// +kubebuilder:validation:Optional
	PRURL string `json:"prUrl,omitempty"`

	// CreatedAt is the timestamp when the PR was created
	// +kubebuilder:validation:Optional
	CreatedAt string `json:"createdAt,omitempty"`

	// LastProcessedTemplateHash is the hash of the last processed template directory
	// Used to detect template changes
	// +kubebuilder:validation:Optional
	LastProcessedTemplateHash string `json:"lastProcessedTemplateHash,omitempty"`

	// LastTemplateCheckTime is the timestamp when templates were last checked
	// +kubebuilder:validation:Optional
	LastTemplateCheckTime *metav1.Time `json:"lastTemplateCheckTime,omitempty"`

	// ErrorMessage contains error details if state is "error"
	// +kubebuilder:validation:Optional
	ErrorMessage string `json:"errorMessage,omitempty"`

	// RemovedAt is the timestamp when the namespace was removed from whitelist
	// Used for status cleanup after retention period
	// +kubebuilder:validation:Optional
	RemovedAt string `json:"removedAt,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status

// PermissionBinder is the Schema for the permissionbinders API
type PermissionBinder struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   PermissionBinderSpec   `json:"spec,omitempty"`
	Status PermissionBinderStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// PermissionBinderList contains a list of PermissionBinder
type PermissionBinderList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []PermissionBinder `json:"items"`
}

func init() {
	SchemeBuilder.Register(&PermissionBinder{}, &PermissionBinderList{})
}
