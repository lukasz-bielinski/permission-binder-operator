package controller

import (
	"testing"

	"github.com/stretchr/testify/require"
)

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

