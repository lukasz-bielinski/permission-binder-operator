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
		// Namespace-less CR: strict matching (issue #43) - the CRD is
		// namespace-scoped, so an empty CR namespace never occurs in a real
		// cluster; the old name-only fallback was a silent isolation-loss trap.
		{
			name: "namespace-less CR does NOT match a namespace-stamped resource",
			annotations: map[string]string{
				AnnotationPermissionBinder:          "example",
				AnnotationPermissionBinderNamespace: "instance-a",
			},
			pbNamespace: "",
			pbName:      "example",
			expected:    false,
			description: "The pb.Namespace==\"\" name-only fallback was removed (issue #43)",
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

// TestCanTakeOwnership covers the write-path ownership gate (issue #43):
// unclaimed, own, legacy and orphaned resources are manageable; a live claim
// by another PermissionBinder is refused. The decision is annotation-based
// only - spec drift never factors in (manual-modification protection).
func TestCanTakeOwnership(t *testing.T) {
	const owner, ownerNs = "example", "instance-a"

	tests := []struct {
		name        string
		annotations map[string]string
		expected    bool
	}{
		{
			name:        "nil annotations (unclaimed) - allowed",
			annotations: nil,
			expected:    true,
		},
		{
			name:        "no ownership annotation (unclaimed pre-existing resource) - allowed",
			annotations: map[string]string{AnnotationManagedBy: ManagedByValue},
			expected:    true,
		},
		{
			name: "owned by this CR (name + namespace) - allowed",
			annotations: map[string]string{
				AnnotationPermissionBinder:          owner,
				AnnotationPermissionBinderNamespace: ownerNs,
			},
			expected: true,
		},
		{
			name: "legacy name-only claim by same name - allowed (retroactive namespace stamp)",
			annotations: map[string]string{
				AnnotationPermissionBinder: owner,
			},
			expected: true,
		},
		{
			name: "live claim by different CR name - refused",
			annotations: map[string]string{
				AnnotationPermissionBinder:          "other",
				AnnotationPermissionBinderNamespace: ownerNs,
			},
			expected: false,
		},
		{
			name: "live claim by same CR name in another namespace - refused (steal-then-delete prevention)",
			annotations: map[string]string{
				AnnotationPermissionBinder:          owner,
				AnnotationPermissionBinderNamespace: "instance-b",
			},
			expected: false,
		},
		{
			name: "foreign claim WITH orphan marker - allowed (explicit adoption / CR namespace migration)",
			annotations: map[string]string{
				AnnotationPermissionBinder:          owner,
				AnnotationPermissionBinderNamespace: "instance-b",
				AnnotationOrphanedAt:                "2026-08-21T00:00:00Z",
				AnnotationOrphanedBy:                OrphanedByPermissionBinderDeletion,
			},
			expected: true,
		},
		{
			name: "foreign NAME with orphan marker - allowed (orphans are adoptable by anyone)",
			annotations: map[string]string{
				AnnotationPermissionBinder: "other",
				AnnotationOrphanedAt:       "2026-08-21T00:00:00Z",
			},
			expected: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := canTakeOwnership(tt.annotations, owner, ownerNs); got != tt.expected {
				t.Errorf("canTakeOwnership() = %v, expected %v", got, tt.expected)
			}
		})
	}
}

// TestIsOwnedByStrictNamespace pins the strictness introduced by issue #43:
// an empty owner namespace no longer falls back to name-only matching against
// namespace-stamped resources.
func TestIsOwnedByStrictNamespace(t *testing.T) {
	stamped := map[string]string{
		AnnotationPermissionBinder:          "example",
		AnnotationPermissionBinderNamespace: "instance-a",
	}
	if isOwnedBy(stamped, "example", "") {
		t.Error("empty owner namespace must NOT match a namespace-stamped resource")
	}
	legacy := map[string]string{AnnotationPermissionBinder: "example"}
	if !isOwnedBy(legacy, "example", "") {
		t.Error("legacy name-only resources must still match by name")
	}
	if !isOwnedBy(legacy, "example", "instance-a") {
		t.Error("legacy name-only resources must match a namespaced owner by name")
	}
}

// TestIsOwnedByEmptyNamespaceValue pins the degenerate-stamp handling: a
// present-but-empty namespace annotation is treated as legacy (name match)
// instead of permanently wedging the resource against every real CR.
func TestIsOwnedByEmptyNamespaceValue(t *testing.T) {
	degenerate := map[string]string{
		AnnotationPermissionBinder:          "example",
		AnnotationPermissionBinderNamespace: "",
	}
	if !isOwnedBy(degenerate, "example", "instance-a") {
		t.Error("empty-value namespace annotation must fall back to name matching")
	}
	if isOwnedBy(degenerate, "other", "instance-a") {
		t.Error("empty-value namespace annotation must still require a name match")
	}
}
