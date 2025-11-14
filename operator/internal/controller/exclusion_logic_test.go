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

