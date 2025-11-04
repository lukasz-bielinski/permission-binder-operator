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
