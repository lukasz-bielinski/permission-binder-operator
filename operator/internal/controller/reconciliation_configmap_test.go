package controller

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// TestCalculateRoleMappingHash tests the hash calculation for role mappings
// This is a pure function test - no external dependencies, fully deterministic
func TestCalculateRoleMappingHash(t *testing.T) {
	reconciler := &PermissionBinderReconciler{}

	tests := []struct {
		name        string
		roleMapping map[string]string
		expectHash  string // empty means just check not empty
		description string
	}{
		{
			name: "empty mapping",
			roleMapping: map[string]string{},
			description: "Empty map should produce consistent hash",
		},
		{
			name: "single role",
			roleMapping: map[string]string{
				"engineer": "edit",
			},
			description: "Single role mapping",
		},
		{
			name: "multiple roles",
			roleMapping: map[string]string{
				"engineer": "edit",
				"admin":    "cluster-admin",
				"viewer":   "view",
			},
			description: "Multiple role mappings",
		},
		{
			name: "same roles different order",
			roleMapping: map[string]string{
				"viewer":   "view",
				"admin":    "cluster-admin",
				"engineer": "edit",
			},
			description: "Order shouldn't matter - hash should be same as 'multiple roles'",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			hash := reconciler.calculateRoleMappingHash(tt.roleMapping)

			// Hash should never be empty (even for empty map)
			require.NotEmpty(t, hash, "Hash should never be empty")

			// Hash should be 64 characters (SHA256 hex)
			assert.Len(t, hash, 64, "SHA256 hash should be 64 hex characters")

			// Hash should be deterministic - same input produces same output
			hash2 := reconciler.calculateRoleMappingHash(tt.roleMapping)
			assert.Equal(t, hash, hash2, "Hash should be deterministic")

			// Store hash for comparison tests
			if tt.expectHash != "" {
				assert.Equal(t, tt.expectHash, hash, tt.description)
			}
		})
	}
}

// TestCalculateRoleMappingHash_Deterministic verifies hash consistency
// Critical for change detection - same input must always produce same hash
func TestCalculateRoleMappingHash_Deterministic(t *testing.T) {
	reconciler := &PermissionBinderReconciler{}

	roleMapping := map[string]string{
		"engineer": "edit",
		"admin":    "cluster-admin",
		"viewer":   "view",
	}

	// Calculate hash multiple times
	hash1 := reconciler.calculateRoleMappingHash(roleMapping)
	hash2 := reconciler.calculateRoleMappingHash(roleMapping)
	hash3 := reconciler.calculateRoleMappingHash(roleMapping)

	// All should be identical
	assert.Equal(t, hash1, hash2, "First and second hash should match")
	assert.Equal(t, hash2, hash3, "Second and third hash should match")
	assert.Equal(t, hash1, hash3, "First and third hash should match")
}

// TestCalculateRoleMappingHash_OrderIndependent verifies that key order doesn't matter
// Critical for change detection - map iteration order is random in Go
func TestCalculateRoleMappingHash_OrderIndependent(t *testing.T) {
	reconciler := &PermissionBinderReconciler{}

	// Same content, different insertion order
	map1 := map[string]string{
		"a": "role-a",
		"b": "role-b",
		"c": "role-c",
	}

	map2 := map[string]string{
		"c": "role-c",
		"a": "role-a",
		"b": "role-b",
	}

	map3 := map[string]string{
		"b": "role-b",
		"c": "role-c",
		"a": "role-a",
	}

	hash1 := reconciler.calculateRoleMappingHash(map1)
	hash2 := reconciler.calculateRoleMappingHash(map2)
	hash3 := reconciler.calculateRoleMappingHash(map3)

	// All should produce the same hash
	assert.Equal(t, hash1, hash2, "Hash should be order-independent (map1 vs map2)")
	assert.Equal(t, hash2, hash3, "Hash should be order-independent (map2 vs map3)")
	assert.Equal(t, hash1, hash3, "Hash should be order-independent (map1 vs map3)")
}

// TestCalculateRoleMappingHash_ChangeSensitivity verifies that any change produces different hash
// Critical for change detection - must detect all changes
func TestCalculateRoleMappingHash_ChangeSensitivity(t *testing.T) {
	reconciler := &PermissionBinderReconciler{}

	original := map[string]string{
		"engineer": "edit",
		"admin":    "cluster-admin",
	}

	tests := []struct {
		name        string
		modified    map[string]string
		description string
	}{
		{
			name: "value changed",
			modified: map[string]string{
				"engineer": "view",  // Changed from "edit"
				"admin":    "cluster-admin",
			},
			description: "Changing a value should produce different hash",
		},
		{
			name: "key added",
			modified: map[string]string{
				"engineer": "edit",
				"admin":    "cluster-admin",
				"viewer":   "view",  // Added
			},
			description: "Adding a key should produce different hash",
		},
		{
			name: "key removed",
			modified: map[string]string{
				"engineer": "edit",
				// "admin" removed
			},
			description: "Removing a key should produce different hash",
		},
		{
			name: "key renamed",
			modified: map[string]string{
				"engineer2": "edit",  // Key changed
				"admin":     "cluster-admin",
			},
			description: "Renaming a key should produce different hash",
		},
	}

	originalHash := reconciler.calculateRoleMappingHash(original)

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			modifiedHash := reconciler.calculateRoleMappingHash(tt.modified)
			assert.NotEqual(t, originalHash, modifiedHash, tt.description)
		})
	}
}

// TestCalculateRoleMappingHash_EdgeCases tests edge cases
func TestCalculateRoleMappingHash_EdgeCases(t *testing.T) {
	reconciler := &PermissionBinderReconciler{}

	tests := []struct {
		name        string
		roleMapping map[string]string
		description string
	}{
		{
			name:        "nil map",
			roleMapping: nil,
			description: "Nil map should not panic",
		},
		{
			name:        "empty map",
			roleMapping: map[string]string{},
			description: "Empty map should not panic",
		},
		{
			name: "empty strings",
			roleMapping: map[string]string{
				"": "",
			},
			description: "Empty key and value should work",
		},
		{
			name: "special characters",
			roleMapping: map[string]string{
				"role-with-dash":       "cluster-admin",
				"role_with_underscore": "edit",
				"role.with.dot":        "view",
			},
			description: "Special characters should work",
		},
		{
			name: "long values",
			roleMapping: map[string]string{
				"role": "very-long-cluster-role-name-that-exceeds-normal-length-expectations-for-testing-purposes",
			},
			description: "Long values should work",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Should not panic
			require.NotPanics(t, func() {
				hash := reconciler.calculateRoleMappingHash(tt.roleMapping)
				// Hash should always be 64 characters (SHA256 hex)
				assert.Len(t, hash, 64, "Hash should be 64 characters")
			}, tt.description)
		})
	}
}

// TestHasRoleMappingChanged tests the change detection logic
// This tests business logic that determines if reconciliation is needed
func TestHasRoleMappingChanged(t *testing.T) {
	reconciler := &PermissionBinderReconciler{}

	tests := []struct {
		name              string
		roleMapping       map[string]string
		lastProcessedHash string
		wantChanged       bool
		description       string
	}{
		{
			name: "first time - no previous hash",
			roleMapping: map[string]string{
				"engineer": "edit",
			},
			lastProcessedHash: "",
			wantChanged:       true,
			description:       "First time processing - should be considered changed",
		},
		{
			name: "no change - same mapping",
			roleMapping: map[string]string{
				"engineer": "edit",
			},
			lastProcessedHash: "will-be-set-to-current",
			wantChanged:       false,
			description:       "Same mapping - should not be changed",
		},
		{
			name: "changed - different mapping",
			roleMapping: map[string]string{
				"engineer": "view", // Changed from "edit"
			},
			lastProcessedHash: "different-hash",
			wantChanged:       true,
			description:       "Different mapping - should be changed",
		},
		{
			name: "changed - role added",
			roleMapping: map[string]string{
				"engineer": "edit",
				"admin":    "cluster-admin", // Added
			},
			lastProcessedHash: "old-hash",
			wantChanged:       true,
			description:       "Role added - should be changed",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create PermissionBinder with role mapping
			pb := &permissionv1.PermissionBinder{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-pb",
					Namespace: "default",
				},
				Spec: permissionv1.PermissionBinderSpec{
					RoleMapping: tt.roleMapping,
				},
				Status: permissionv1.PermissionBinderStatus{},
			}

			// For "no change" test, set lastProcessedHash to current hash
			if tt.lastProcessedHash == "will-be-set-to-current" {
				currentHash := reconciler.calculateRoleMappingHash(tt.roleMapping)
				pb.Status.LastProcessedRoleMappingHash = currentHash
			} else {
				pb.Status.LastProcessedRoleMappingHash = tt.lastProcessedHash
			}

			// Test change detection
			changed, currentHash := reconciler.hasRoleMappingChanged(pb)

			// Verify result
			assert.Equal(t, tt.wantChanged, changed, tt.description)

			// Verify current hash is always returned
			require.NotEmpty(t, currentHash, "Current hash should always be returned")
			assert.Len(t, currentHash, 64, "Hash should be 64 characters")

			// Verify current hash matches what calculateRoleMappingHash would return
			expectedHash := reconciler.calculateRoleMappingHash(tt.roleMapping)
			assert.Equal(t, expectedHash, currentHash, "Returned hash should match calculated hash")
		})
	}
}

// TestHasRoleMappingChanged_EmptyMap tests behavior with empty role mapping
func TestHasRoleMappingChanged_EmptyMap(t *testing.T) {
	reconciler := &PermissionBinderReconciler{}

	pb := &permissionv1.PermissionBinder{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-pb",
			Namespace: "default",
		},
		Spec: permissionv1.PermissionBinderSpec{
			RoleMapping: map[string]string{},
		},
		Status: permissionv1.PermissionBinderStatus{
			LastProcessedRoleMappingHash: "",
		},
	}

	// First time with empty map
	changed, hash1 := reconciler.hasRoleMappingChanged(pb)
	assert.True(t, changed, "First time should be considered changed")
	assert.NotEmpty(t, hash1, "Hash should be returned even for empty map")

	// Second time with empty map (same hash)
	pb.Status.LastProcessedRoleMappingHash = hash1
	changed2, hash2 := reconciler.hasRoleMappingChanged(pb)
	assert.False(t, changed2, "Same empty map should not be changed")
	assert.Equal(t, hash1, hash2, "Hash should be consistent")
}

// TestHasRoleMappingChanged_NilMap tests behavior with nil role mapping
func TestHasRoleMappingChanged_NilMap(t *testing.T) {
	reconciler := &PermissionBinderReconciler{}

	pb := &permissionv1.PermissionBinder{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-pb",
			Namespace: "default",
		},
		Spec: permissionv1.PermissionBinderSpec{
			RoleMapping: nil, // Nil map
		},
		Status: permissionv1.PermissionBinderStatus{
			LastProcessedRoleMappingHash: "",
		},
	}

	// Should not panic with nil map
	require.NotPanics(t, func() {
		changed, hash := reconciler.hasRoleMappingChanged(pb)
		assert.True(t, changed, "First time should be considered changed")
		assert.NotEmpty(t, hash, "Hash should be returned even for nil map")
	})
}

// TestHasRoleMappingChanged_Integration tests realistic scenario
// This simulates what happens during actual reconciliation
func TestHasRoleMappingChanged_Integration(t *testing.T) {
	reconciler := &PermissionBinderReconciler{}

	// Step 1: First reconciliation - no previous hash
	pb := &permissionv1.PermissionBinder{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-pb",
			Namespace: "default",
		},
		Spec: permissionv1.PermissionBinderSpec{
			RoleMapping: map[string]string{
				"engineer": "edit",
				"admin":    "cluster-admin",
			},
		},
		Status: permissionv1.PermissionBinderStatus{
			LastProcessedRoleMappingHash: "",
		},
	}

	// First check - should be changed (no previous hash)
	changed1, hash1 := reconciler.hasRoleMappingChanged(pb)
	assert.True(t, changed1, "First reconciliation should detect change")
	assert.NotEmpty(t, hash1, "Hash should be generated")

	// Step 2: Update status with current hash (simulating successful reconciliation)
	pb.Status.LastProcessedRoleMappingHash = hash1

	// Second check - should NOT be changed (same mapping)
	changed2, hash2 := reconciler.hasRoleMappingChanged(pb)
	assert.False(t, changed2, "Second reconciliation with same mapping should not detect change")
	assert.Equal(t, hash1, hash2, "Hash should remain the same")

	// Step 3: User updates role mapping
	pb.Spec.RoleMapping["viewer"] = "view" // Added new role

	// Third check - should be changed (mapping modified)
	changed3, hash3 := reconciler.hasRoleMappingChanged(pb)
	assert.True(t, changed3, "Third reconciliation with modified mapping should detect change")
	assert.NotEqual(t, hash1, hash3, "Hash should be different after modification")

	// Step 4: Update status with new hash
	pb.Status.LastProcessedRoleMappingHash = hash3

	// Fourth check - should NOT be changed (mapping stabilized)
	changed4, hash4 := reconciler.hasRoleMappingChanged(pb)
	assert.False(t, changed4, "Fourth reconciliation should not detect change")
	assert.Equal(t, hash3, hash4, "Hash should match after reconciliation")
}

