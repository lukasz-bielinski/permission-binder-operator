package controller

import (
	"reflect"
	"testing"
)

// TestGetMapKeys tests the getMapKeys function
func TestGetMapKeys(t *testing.T) {
	tests := []struct {
		name     string
		input    map[string]string
		expected []string // We'll check length and presence, not order
	}{
		{
			name: "Standard map with 3 keys",
			input: map[string]string{
				"admin":    "cluster-admin",
				"engineer": "edit",
				"viewer":   "view",
			},
			expected: []string{"admin", "engineer", "viewer"},
		},
		{
			name: "Single key map",
			input: map[string]string{
				"developer": "edit",
			},
			expected: []string{"developer"},
		},
		{
			name:     "Empty map",
			input:    map[string]string{},
			expected: []string{},
		},
		{
			name: "Map with numeric keys",
			input: map[string]string{
				"role1": "admin",
				"role2": "editor",
				"role3": "viewer",
			},
			expected: []string{"role1", "role2", "role3"},
		},
		{
			name: "Map with keys containing special characters",
			input: map[string]string{
				"read-only":     "view",
				"super_admin":   "cluster-admin",
				"app.developer": "edit",
			},
			expected: []string{"read-only", "super_admin", "app.developer"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := getMapKeys(tt.input)

			// Check length
			if len(result) != len(tt.expected) {
				t.Errorf("Expected %d keys, got %d", len(tt.expected), len(result))
				return
			}

			// Check all expected keys are present (order doesn't matter)
			expectedMap := make(map[string]bool)
			for _, key := range tt.expected {
				expectedMap[key] = true
			}

			for _, key := range result {
				if !expectedMap[key] {
					t.Errorf("Unexpected key in result: %q", key)
				}
			}
		})
	}
}

// TestContainsString tests the containsString function
func TestContainsString(t *testing.T) {
	tests := []struct {
		name     string
		slice    []string
		search   string
		expected bool
	}{
		{
			name:     "String found in middle",
			slice:    []string{"apple", "banana", "cherry"},
			search:   "banana",
			expected: true,
		},
		{
			name:     "String found at start",
			slice:    []string{"apple", "banana", "cherry"},
			search:   "apple",
			expected: true,
		},
		{
			name:     "String found at end",
			slice:    []string{"apple", "banana", "cherry"},
			search:   "cherry",
			expected: true,
		},
		{
			name:     "String not found",
			slice:    []string{"apple", "banana", "cherry"},
			search:   "orange",
			expected: false,
		},
		{
			name:     "Empty slice",
			slice:    []string{},
			search:   "apple",
			expected: false,
		},
		{
			name:     "Single element - found",
			slice:    []string{"apple"},
			search:   "apple",
			expected: true,
		},
		{
			name:     "Single element - not found",
			slice:    []string{"apple"},
			search:   "banana",
			expected: false,
		},
		{
			name:     "Search for empty string - found",
			slice:    []string{"apple", "", "banana"},
			search:   "",
			expected: true,
		},
		{
			name:     "Search for empty string - not found",
			slice:    []string{"apple", "banana"},
			search:   "",
			expected: false,
		},
		{
			name:     "Case sensitive - lowercase",
			slice:    []string{"Apple", "Banana", "Cherry"},
			search:   "apple",
			expected: false,
		},
		{
			name:     "Case sensitive - uppercase",
			slice:    []string{"apple", "banana", "cherry"},
			search:   "Apple",
			expected: false,
		},
		{
			name:     "Duplicate strings in slice",
			slice:    []string{"apple", "banana", "apple", "cherry"},
			search:   "apple",
			expected: true,
		},
		{
			name:     "Namespace in exclude list (real-world)",
			slice:    []string{"kube-system", "kube-public", "default"},
			search:   "kube-system",
			expected: true,
		},
		{
			name:     "Namespace not in exclude list",
			slice:    []string{"kube-system", "kube-public", "default"},
			search:   "my-app",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := containsString(tt.slice, tt.search)
			if result != tt.expected {
				t.Errorf("Expected %v, got %v", tt.expected, result)
			}
		})
	}
}

// TestRemoveString tests the removeString function
func TestRemoveString(t *testing.T) {
	tests := []struct {
		name     string
		slice    []string
		remove   string
		expected []string
	}{
		{
			name:     "Remove from middle",
			slice:    []string{"apple", "banana", "cherry"},
			remove:   "banana",
			expected: []string{"apple", "cherry"},
		},
		{
			name:     "Remove from start",
			slice:    []string{"apple", "banana", "cherry"},
			remove:   "apple",
			expected: []string{"banana", "cherry"},
		},
		{
			name:     "Remove from end",
			slice:    []string{"apple", "banana", "cherry"},
			remove:   "cherry",
			expected: []string{"apple", "banana"},
		},
		{
			name:     "String not found - no change",
			slice:    []string{"apple", "banana", "cherry"},
			remove:   "orange",
			expected: []string{"apple", "banana", "cherry"},
		},
		{
			name:     "Empty slice",
			slice:    []string{},
			remove:   "apple",
			expected: nil,
		},
		{
			name:     "Single element - remove it",
			slice:    []string{"apple"},
			remove:   "apple",
			expected: nil,
		},
		{
			name:     "Single element - not found",
			slice:    []string{"apple"},
			remove:   "banana",
			expected: []string{"apple"},
		},
		{
			name:     "Remove empty string",
			slice:    []string{"apple", "", "banana"},
			remove:   "",
			expected: []string{"apple", "banana"},
		},
		{
			name:     "Remove all occurrences (duplicates)",
			slice:    []string{"apple", "banana", "apple", "cherry", "apple"},
			remove:   "apple",
			expected: []string{"banana", "cherry"},
		},
		{
			name:     "Case sensitive - no match",
			slice:    []string{"Apple", "Banana", "Cherry"},
			remove:   "apple",
			expected: []string{"Apple", "Banana", "Cherry"},
		},
		{
			name:     "All elements are the same - remove all",
			slice:    []string{"apple", "apple", "apple"},
			remove:   "apple",
			expected: nil,
		},
		{
			name:     "Real-world: Remove namespace from list",
			slice:    []string{"app-namespace-1", "app-namespace-2", "app-namespace-3"},
			remove:   "app-namespace-2",
			expected: []string{"app-namespace-1", "app-namespace-3"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := removeString(tt.slice, tt.remove)

			// Check length
			if len(result) != len(tt.expected) {
				t.Errorf("Expected length %d, got %d", len(tt.expected), len(result))
				return
			}

			// Check elements match (order matters)
			if !reflect.DeepEqual(result, tt.expected) {
				t.Errorf("Expected %v, got %v", tt.expected, result)
			}
		})
	}
}

// BenchmarkGetMapKeys - Performance benchmark
func BenchmarkGetMapKeys(b *testing.B) {
	testMap := map[string]string{
		"admin":     "cluster-admin",
		"engineer":  "edit",
		"viewer":    "view",
		"developer": "edit",
		"reader":    "view",
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = getMapKeys(testMap)
	}
}

func BenchmarkGetMapKeys_Large(b *testing.B) {
	// Large map (100 keys)
	testMap := make(map[string]string, 100)
	for i := 0; i < 100; i++ {
		testMap[string(rune('a'+i%26))+string(rune('0'+i))] = "role"
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = getMapKeys(testMap)
	}
}

// BenchmarkContainsString - Performance benchmark
func BenchmarkContainsString(b *testing.B) {
	slice := []string{"apple", "banana", "cherry", "date", "elderberry"}
	search := "cherry"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = containsString(slice, search)
	}
}

func BenchmarkContainsString_NotFound(b *testing.B) {
	slice := []string{"apple", "banana", "cherry", "date", "elderberry"}
	search := "orange"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = containsString(slice, search)
	}
}

func BenchmarkContainsString_Large(b *testing.B) {
	// Large slice (100 elements)
	slice := make([]string, 100)
	for i := 0; i < 100; i++ {
		slice[i] = string(rune('a' + i%26))
	}
	search := "z"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = containsString(slice, search)
	}
}

// BenchmarkRemoveString - Performance benchmark
func BenchmarkRemoveString(b *testing.B) {
	slice := []string{"apple", "banana", "cherry", "date", "elderberry"}
	remove := "cherry"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = removeString(slice, remove)
	}
}

func BenchmarkRemoveString_NotFound(b *testing.B) {
	slice := []string{"apple", "banana", "cherry", "date", "elderberry"}
	remove := "orange"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = removeString(slice, remove)
	}
}

func BenchmarkRemoveString_Large(b *testing.B) {
	// Large slice (100 elements)
	slice := make([]string, 100)
	for i := 0; i < 100; i++ {
		slice[i] = string(rune('a' + i%26))
	}
	remove := "z"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = removeString(slice, remove)
	}
}
