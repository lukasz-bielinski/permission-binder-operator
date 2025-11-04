package controller

import (
	"testing"

	"github.com/stretchr/testify/require"
)

// TestIsExcluded tests the isExcluded function
func TestIsExcluded(t *testing.T) {
	tests := []struct {
		name        string
		key         string
		excludeList []string
		expected    bool
	}{
		// Basic cases - Key in list
		{
			name:        "Key found in exclude list",
			key:         "kube-system",
			excludeList: []string{"kube-system", "kube-public", "default"},
			expected:    true,
		},
		{
			name:        "Key at start of list",
			key:         "kube-system",
			excludeList: []string{"kube-system", "monitoring", "default"},
			expected:    true,
		},
		{
			name:        "Key at end of list",
			key:         "default",
			excludeList: []string{"kube-system", "kube-public", "default"},
			expected:    true,
		},

		// Basic cases - Key not in list
		{
			name:        "Key not in exclude list",
			key:         "my-app",
			excludeList: []string{"kube-system", "kube-public", "default"},
			expected:    false,
		},
		{
			name:        "Similar but not exact match",
			key:         "kube-system-prod",
			excludeList: []string{"kube-system", "kube-public"},
			expected:    false,
		},

		// Edge cases - Empty lists
		{
			name:        "Empty exclude list",
			key:         "kube-system",
			excludeList: []string{},
			expected:    false,
		},
		{
			name:        "Nil exclude list",
			key:         "kube-system",
			excludeList: nil,
			expected:    false,
		},

		// Edge cases - Empty key
		{
			name:        "Empty key - not in list",
			key:         "",
			excludeList: []string{"kube-system", "default"},
			expected:    false,
		},
		{
			name:        "Empty key - in list",
			key:         "",
			excludeList: []string{"", "kube-system"},
			expected:    true,
		},

		// Case sensitivity
		{
			name:        "Case sensitive - lowercase key",
			key:         "kube-system",
			excludeList: []string{"KUBE-SYSTEM", "default"},
			expected:    false,
		},
		{
			name:        "Case sensitive - uppercase key",
			key:         "KUBE-SYSTEM",
			excludeList: []string{"kube-system", "default"},
			expected:    false,
		},

		// Duplicates in list
		{
			name:        "Key appears multiple times in list",
			key:         "kube-system",
			excludeList: []string{"kube-system", "default", "kube-system"},
			expected:    true,
		},

		// Real-world scenarios
		{
			name:        "Standard Kubernetes system namespaces",
			key:         "kube-node-lease",
			excludeList: []string{"kube-system", "kube-public", "kube-node-lease", "default"},
			expected:    true,
		},
		{
			name:        "Application namespace - not excluded",
			key:         "production-app",
			excludeList: []string{"kube-system", "kube-public", "default", "test"},
			expected:    false,
		},
		{
			name:        "Monitoring namespace - excluded",
			key:         "monitoring",
			excludeList: []string{"kube-system", "kube-public", "monitoring", "logging"},
			expected:    true,
		},

		// Single element list
		{
			name:        "Single element - found",
			key:         "kube-system",
			excludeList: []string{"kube-system"},
			expected:    true,
		},
		{
			name:        "Single element - not found",
			key:         "my-app",
			excludeList: []string{"kube-system"},
			expected:    false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := &PermissionBinderReconciler{}
			result := r.isExcluded(tt.key, tt.excludeList)
			require.Equal(t, tt.expected, result)
		})
	}
}

// TestExtractRoleFromRoleBindingName tests the extractRoleFromRoleBindingName function
func TestExtractRoleFromRoleBindingName(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		// Standard RoleBinding names
		{
			name:     "Standard format: namespace-role",
			input:    "my-app-edit",
			expected: "edit",
		},
		{
			name:     "Format: namespace-role (view)",
			input:    "production-view",
			expected: "view",
		},
		{
			name:     "Format: namespace-role (admin)",
			input:    "test-namespace-admin",
			expected: "admin",
		},

		// Multiple hyphens in namespace
		{
			name:     "Multiple hyphens: extract last segment",
			input:    "my-complex-namespace-name-edit",
			expected: "edit",
		},
		{
			name:     "Many segments",
			input:    "app-v1-test-staging-cluster-admin",
			expected: "admin",
		},

		// Edge cases - No hyphens
		{
			name:     "No hyphens",
			input:    "admin",
			expected: "",
		},
		{
			name:     "Single segment",
			input:    "role",
			expected: "",
		},

		// Edge cases - Single hyphen
		{
			name:     "Single hyphen: two segments",
			input:    "ns-role",
			expected: "role",
		},

		// Edge cases - Empty string
		{
			name:     "Empty string",
			input:    "",
			expected: "",
		},

		// Edge cases - Trailing hyphen
		{
			name:     "Trailing hyphen",
			input:    "my-app-",
			expected: "",
		},
		{
			name:     "Leading hyphen",
			input:    "-my-app",
			expected: "app",
		},

		// Real-world examples
		{
			name:     "Example: test-namespace-001-edit",
			input:    "test-namespace-001-edit",
			expected: "edit",
		},
		{
			name:     "Example: production-k8s-app-cluster-admin",
			input:    "production-k8s-app-cluster-admin",
			expected: "admin",
		},
		{
			name:     "Example: dev-staging-view",
			input:    "dev-staging-view",
			expected: "view",
		},

		// Role names with hyphens
		{
			name:     "Role with hyphen: cluster-admin",
			input:    "my-namespace-cluster-admin",
			expected: "admin",
		},
		{
			name:     "Role with hyphen: read-only",
			input:    "production-read-only",
			expected: "only",
		},

		// Very long names
		{
			name:     "Very long namespace name",
			input:    "very-long-namespace-name-with-many-segments-and-identifiers-edit",
			expected: "edit",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := &PermissionBinderReconciler{}
			result := r.extractRoleFromRoleBindingName(tt.input)
			require.Equal(t, tt.expected, result)
		})
	}
}

// TestExtractRoleFromRoleBindingNameWithMapping tests the extractRoleFromRoleBindingNameWithMapping function
// This function correctly handles roles with hyphens (e.g., "read-only", "cluster-admin")
func TestExtractRoleFromRoleBindingNameWithMapping(t *testing.T) {
	standardMapping := map[string]string{
		"admin":         "cluster-admin",
		"engineer":      "edit",
		"developer":     "edit",
		"viewer":        "view",
		"read-only":     "view",
		"cluster-admin": "cluster-admin",
		"only":          "view", // Edge case: shorter role name
	}

	tests := []struct {
		name        string
		input       string
		roleMapping map[string]string
		expected    string
	}{
		// Standard roles (no hyphens)
		{
			name:        "Standard format: namespace-role",
			input:       "my-app-edit",
			roleMapping: standardMapping,
			expected:    "edit",
		},
		{
			name:        "Format: namespace-role (view)",
			input:       "production-view",
			roleMapping: standardMapping,
			expected:    "view",
		},
		{
			name:        "Format: namespace-role (admin)",
			input:       "test-namespace-admin",
			roleMapping: standardMapping,
			expected:    "admin",
		},

		// Roles with hyphens - NEW FUNCTION SHOULD HANDLE THESE
		{
			name:        "Role with hyphen: read-only (should return full name)",
			input:       "production-read-only",
			roleMapping: standardMapping,
			expected:    "read-only", // NEW: Should return "read-only", not "only"
		},
		{
			name:        "Role with hyphen: cluster-admin (should return full name)",
			input:       "my-namespace-cluster-admin",
			roleMapping: standardMapping,
			expected:    "cluster-admin", // NEW: Should return "cluster-admin", not "admin"
		},
		{
			name:        "Longest role match preferred (read-only vs only)",
			input:       "production-read-only",
			roleMapping: map[string]string{"read-only": "view", "only": "view"},
			expected:    "read-only", // Should prefer longer match
		},

		// Multiple hyphens in namespace
		{
			name:        "Multiple hyphens: extract longest role",
			input:       "my-complex-namespace-name-read-only",
			roleMapping: standardMapping,
			expected:    "read-only",
		},
		{
			name:        "Many segments with hyphenated role",
			input:       "app-v1-test-staging-cluster-admin",
			roleMapping: standardMapping,
			expected:    "cluster-admin",
		},

		// Edge cases
		{
			name:        "No hyphens",
			input:       "admin",
			roleMapping: standardMapping,
			expected:    "", // Fallback to legacy behavior
		},
		{
			name:        "Single hyphen: two segments",
			input:       "ns-role",
			roleMapping: map[string]string{"role": "view"},
			expected:    "role",
		},
		{
			name:        "Empty string",
			input:       "",
			roleMapping: standardMapping,
			expected:    "",
		},

		// Real-world examples
		{
			name:        "Example: test-namespace-001-read-only",
			input:       "test-namespace-001-read-only",
			roleMapping: standardMapping,
			expected:    "read-only",
		},
		{
			name:        "Example: production-k8s-app-cluster-admin",
			input:       "production-k8s-app-cluster-admin",
			roleMapping: standardMapping,
			expected:    "cluster-admin",
		},

		// Bug fix verification: roles with hyphens should not extract last segment only
		{
			name:        "BUG FIX: read-only should not extract 'only'",
			input:       "production-read-only",
			roleMapping: map[string]string{"read-only": "view", "only": "view"},
			expected:    "read-only", // Must be "read-only", NOT "only"
		},
		{
			name:        "BUG FIX: cluster-admin should not extract 'admin'",
			input:       "namespace-cluster-admin",
			roleMapping: map[string]string{"cluster-admin": "cluster-admin", "admin": "admin"},
			expected:    "cluster-admin", // Must be "cluster-admin", NOT "admin"
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := &PermissionBinderReconciler{}
			result := r.extractRoleFromRoleBindingNameWithMapping(tt.input, tt.roleMapping)
			require.Equal(t, tt.expected, result, "Expected %q but got %q for input %q", tt.expected, result, tt.input)
		})
	}
}

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

// BenchmarkIsExcluded - Performance benchmark
func BenchmarkIsExcluded(b *testing.B) {
	r := &PermissionBinderReconciler{}
	excludeList := []string{"kube-system", "kube-public", "kube-node-lease", "default"}
	key := "kube-system"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = r.isExcluded(key, excludeList)
	}
}

func BenchmarkIsExcluded_NotFound(b *testing.B) {
	r := &PermissionBinderReconciler{}
	excludeList := []string{"kube-system", "kube-public", "kube-node-lease", "default"}
	key := "my-app"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = r.isExcluded(key, excludeList)
	}
}

func BenchmarkIsExcluded_Large(b *testing.B) {
	r := &PermissionBinderReconciler{}
	// Large exclude list (50 namespaces)
	excludeList := make([]string, 50)
	for i := 0; i < 50; i++ {
		excludeList[i] = "namespace-" + string(rune('a'+i%26))
	}
	key := "namespace-z"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = r.isExcluded(key, excludeList)
	}
}

// BenchmarkExtractRoleFromRoleBindingName - Performance benchmark
func BenchmarkExtractRoleFromRoleBindingName(b *testing.B) {
	r := &PermissionBinderReconciler{}
	name := "my-complex-namespace-name-edit"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = r.extractRoleFromRoleBindingName(name)
	}
}

func BenchmarkExtractRoleFromRoleBindingName_Long(b *testing.B) {
	r := &PermissionBinderReconciler{}
	name := "very-long-namespace-name-with-many-segments-and-identifiers-cluster-admin"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = r.extractRoleFromRoleBindingName(name)
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
