package controller

import (
	"testing"

	"github.com/stretchr/testify/require"
)

// TestRoleExistsInMapping tests the roleExistsInMapping function
func TestRoleExistsInMapping(t *testing.T) {
	standardMapping := map[string]string{
		"admin":     "cluster-admin",
		"engineer":  "edit",
		"developer": "edit",
		"viewer":    "view",
		"read-only": "view",
	}

	tests := []struct {
		name     string
		role     string
		mapping  map[string]string
		expected bool
	}{
		// Role exists
		{
			name:     "Role exists - admin",
			role:     "admin",
			mapping:  standardMapping,
			expected: true,
		},
		{
			name:     "Role exists - engineer",
			role:     "engineer",
			mapping:  standardMapping,
			expected: true,
		},
		{
			name:     "Role exists - viewer",
			role:     "viewer",
			mapping:  standardMapping,
			expected: true,
		},

		// Role doesn't exist
		{
			name:     "Role not in mapping",
			role:     "superuser",
			mapping:  standardMapping,
			expected: false,
		},
		{
			name:     "Role not in mapping - guest",
			role:     "guest",
			mapping:  standardMapping,
			expected: false,
		},

		// Case sensitivity
		{
			name:     "Case sensitive - uppercase role",
			role:     "ADMIN",
			mapping:  standardMapping,
			expected: false,
		},
		{
			name:     "Case sensitive - mixed case",
			role:     "Admin",
			mapping:  standardMapping,
			expected: false,
		},

		// Empty cases
		{
			name:     "Empty role",
			role:     "",
			mapping:  standardMapping,
			expected: false,
		},
		{
			name:     "Empty mapping",
			role:     "admin",
			mapping:  map[string]string{},
			expected: false,
		},
		{
			name:     "Nil mapping",
			role:     "admin",
			mapping:  nil,
			expected: false,
		},

		// Single element mapping
		{
			name:     "Single element mapping - found",
			role:     "admin",
			mapping:  map[string]string{"admin": "cluster-admin"},
			expected: true,
		},
		{
			name:     "Single element mapping - not found",
			role:     "viewer",
			mapping:  map[string]string{"admin": "cluster-admin"},
			expected: false,
		},

		// Role names with special characters
		{
			name:     "Role with hyphen - exists",
			role:     "read-only",
			mapping:  standardMapping,
			expected: true,
		},
		{
			name: "Role with underscore - exists",
			role: "super_admin",
			mapping: map[string]string{
				"super_admin": "cluster-admin",
				"viewer":      "view",
			},
			expected: true,
		},

		// Real-world scenarios
		{
			name:     "Standard role - edit",
			role:     "engineer",
			mapping:  standardMapping,
			expected: true,
		},
		{
			name:     "Standard role - view",
			role:     "viewer",
			mapping:  standardMapping,
			expected: true,
		},
		{
			name:     "Custom role - not in standard mapping",
			role:     "backup-operator",
			mapping:  standardMapping,
			expected: false,
		},

		// ClusterRole values (not keys)
		{
			name:     "ClusterRole value - not a key",
			role:     "cluster-admin",
			mapping:  standardMapping,
			expected: false, // "cluster-admin" is a value, not a key
		},
		{
			name:     "ClusterRole value - edit",
			role:     "edit",
			mapping:  standardMapping,
			expected: false, // "edit" is a value, not a key
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := &PermissionBinderReconciler{}
			result := r.roleExistsInMapping(tt.role, tt.mapping)
			require.Equal(t, tt.expected, result)
		})
	}
}

// BenchmarkRoleExistsInMapping - Performance benchmark
func BenchmarkRoleExistsInMapping(b *testing.B) {
	r := &PermissionBinderReconciler{}
	mapping := map[string]string{
		"admin":     "cluster-admin",
		"engineer":  "edit",
		"developer": "edit",
		"viewer":    "view",
		"read-only": "view",
	}
	role := "engineer"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = r.roleExistsInMapping(role, mapping)
	}
}

func BenchmarkRoleExistsInMapping_NotFound(b *testing.B) {
	r := &PermissionBinderReconciler{}
	mapping := map[string]string{
		"admin":     "cluster-admin",
		"engineer":  "edit",
		"developer": "edit",
		"viewer":    "view",
		"read-only": "view",
	}
	role := "superuser"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = r.roleExistsInMapping(role, mapping)
	}
}

func BenchmarkRoleExistsInMapping_Large(b *testing.B) {
	r := &PermissionBinderReconciler{}
	// Large mapping (100 roles)
	mapping := make(map[string]string, 100)
	for i := 0; i < 100; i++ {
		mapping["role-"+string(rune('a'+i%26))+string(rune('0'+i/26))] = "edit"
	}
	role := "role-z9"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = r.roleExistsInMapping(role, mapping)
	}
}

