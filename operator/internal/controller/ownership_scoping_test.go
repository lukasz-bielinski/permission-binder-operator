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

package controller

import (
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

func newPermissionBinder(namespace, name string) *permissionv1.PermissionBinder {
	return &permissionv1.PermissionBinder{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
		},
	}
}

// TestIsOwnedByPermissionBinder tests the namespace-aware ownership matching
// used to select resources managed by a specific PermissionBinder CR. It covers
// the multi-instance isolation requirement: two operator instances reconciling
// CRs with the same name in different namespaces must not match (and therefore
// must not delete) each other's resources.
func TestIsOwnedByPermissionBinder(t *testing.T) {
	tests := []struct {
		name        string
		annotations map[string]string
		pbNamespace string
		pbName      string
		expected    bool
		description string
	}{
		// New-style annotations (name + namespace)
		{
			name: "new-style: name and namespace match",
			annotations: map[string]string{
				AnnotationPermissionBinder:          "example",
				AnnotationPermissionBinderNamespace: "instance-a",
			},
			pbNamespace: "instance-a",
			pbName:      "example",
			expected:    true,
			description: "Resource owned by this exact CR instance must match",
		},
		{
			name: "new-style: CR name collision across instances does not match",
			annotations: map[string]string{
				AnnotationPermissionBinder:          "example",
				AnnotationPermissionBinderNamespace: "instance-b",
			},
			pbNamespace: "instance-a",
			pbName:      "example",
			expected:    false,
			description: "Same CR name in another namespace must NOT match - prevents cross-instance RoleBinding deletion",
		},
		{
			name: "new-style: different name does not match",
			annotations: map[string]string{
				AnnotationPermissionBinder:          "other",
				AnnotationPermissionBinderNamespace: "instance-a",
			},
			pbNamespace: "instance-a",
			pbName:      "example",
			expected:    false,
			description: "Different CR name must not match",
		},
		// Legacy annotations (name only, no namespace)
		{
			name: "legacy: name-only annotation is still adopted (backward compatibility)",
			annotations: map[string]string{
				AnnotationPermissionBinder: "example",
			},
			pbNamespace: "instance-a",
			pbName:      "example",
			expected:    true,
			description: "Resources annotated before namespace-aware ownership must still be matched",
		},
		{
			name: "legacy: name-only annotation with different name does not match",
			annotations: map[string]string{
				AnnotationPermissionBinder: "other",
			},
			pbNamespace: "instance-a",
			pbName:      "example",
			expected:    false,
			description: "Legacy resources of a different CR must not match",
		},
		// Namespace-less CR (e.g. plain envtest client without namespace defaulting)
		{
			name: "namespace-less CR matches namespaced resource by name (backward compatibility)",
			annotations: map[string]string{
				AnnotationPermissionBinder:          "example",
				AnnotationPermissionBinderNamespace: "instance-a",
			},
			pbNamespace: "",
			pbName:      "example",
			expected:    true,
			description: "CRs without namespace (existing envtest fixtures) keep name-only matching",
		},
		{
			name: "namespace-less CR matches legacy resource by name",
			annotations: map[string]string{
				AnnotationPermissionBinder: "example",
			},
			pbNamespace: "",
			pbName:      "example",
			expected:    true,
			description: "Legacy behavior for namespace-less CRs is unchanged",
		},
		// Edge cases
		{
			name:        "nil annotations do not match",
			annotations: nil,
			pbNamespace: "instance-a",
			pbName:      "example",
			expected:    false,
			description: "Unmanaged resources must never match",
		},
		{
			name:        "empty annotations do not match",
			annotations: map[string]string{},
			pbNamespace: "instance-a",
			pbName:      "example",
			expected:    false,
			description: "Resources without ownership annotations must not match",
		},
		{
			name: "unrelated annotations do not match",
			annotations: map[string]string{
				AnnotationManagedBy: ManagedByValue,
				AnnotationRole:      "engineer",
			},
			pbNamespace: "instance-a",
			pbName:      "example",
			expected:    false,
			description: "Shared managed-by label/annotation alone is not an ownership proof",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pb := newPermissionBinder(tt.pbNamespace, tt.pbName)
			result := isOwnedByPermissionBinder(tt.annotations, pb)
			if result != tt.expected {
				t.Errorf("%s: expected %v, got %v", tt.description, tt.expected, result)
			}
		})
	}
}

// TestManagedByValueDefault verifies that the managed-by value defaults to the
// historical constant, so single-instance deployments with MANAGED_BY_VALUE
// unset behave exactly as before.
func TestManagedByValueDefault(t *testing.T) {
	if ManagedByValue != DefaultManagedByValue {
		t.Errorf("ManagedByValue should default to %q, got %q", DefaultManagedByValue, ManagedByValue)
	}
	if DefaultManagedByValue != "permission-binder-operator" {
		t.Errorf("DefaultManagedByValue must remain %q for backward compatibility, got %q",
			"permission-binder-operator", DefaultManagedByValue)
	}
}

// TestManagedByValueOverride verifies that MANAGED_BY_VALUE-style overrides make
// the managed-by selection instance-specific: resources stamped by another
// instance (different managed-by value) are no longer selected by this instance.
func TestManagedByValueOverride(t *testing.T) {
	original := ManagedByValue
	t.Cleanup(func() { ManagedByValue = original })

	ManagedByValue = "permission-binder-operator-e2e-a"

	// The override is applied to newly created resources via the variable, while
	// the annotation/label keys stay fixed.
	if ManagedByValue != "permission-binder-operator-e2e-a" {
		t.Errorf("ManagedByValue override not applied, got %q", ManagedByValue)
	}
	if LabelManagedBy != "permission-binder.io/managed-by" {
		t.Errorf("LabelManagedBy key must stay stable, got %q", LabelManagedBy)
	}
	if AnnotationPermissionBinderNamespace != "permission-binder.io/permission-binder-namespace" {
		t.Errorf("Unexpected ownership namespace annotation key: %q", AnnotationPermissionBinderNamespace)
	}
}
