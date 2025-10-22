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
}

// PermissionBinderStatus defines the observed state of PermissionBinder
type PermissionBinderStatus struct {
	// ProcessedRoleBindings contains the list of successfully created RoleBindings
	ProcessedRoleBindings []string `json:"processedRoleBindings,omitempty"`

	// LastProcessedConfigMapVersion tracks the last processed ConfigMap version
	LastProcessedConfigMapVersion string `json:"lastProcessedConfigMapVersion,omitempty"`

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
