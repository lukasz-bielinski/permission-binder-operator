package controller

import (
	"testing"
)

// TestParsePermissionString tests the parsePermissionString function
func TestParsePermissionString(t *testing.T) {
	r := &PermissionBinderReconciler{}

	// Standard role mapping for most tests
	standardRoleMapping := map[string]string{
		"admin":     "admin",
		"engineer":  "edit",
		"viewer":    "view",
		"read-only": "view",
		"developer": "developer",
	}

	tests := []struct {
		name             string
		permissionString string
		prefix           string
		roleMapping      map[string]string
		expectedNS       string
		expectedRole     string
		expectError      bool
	}{
		// Valid cases - Standard formats
		{
			name:             "Simple permission string",
			permissionString: "COMPANY-K8S-app-admin",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "app",
			expectedRole:     "admin",
			expectError:      false,
		},
		{
			name:             "Namespace with single hyphen",
			permissionString: "COMPANY-K8S-project-123-admin",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "project-123",
			expectedRole:     "admin",
			expectError:      false,
		},
		{
			name:             "Namespace with multiple hyphens",
			permissionString: "COMPANY-K8S-my-app-staging-v2-engineer",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "my-app-staging-v2",
			expectedRole:     "engineer",
			expectError:      false,
		},
		{
			name:             "Namespace with numbers",
			permissionString: "COMPANY-K8S-app123-viewer",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "app123",
			expectedRole:     "viewer",
			expectError:      false,
		},

		// Valid cases - Multi-tenant prefixes
		{
			name:             "Multi-tenant prefix (MT-K8S)",
			permissionString: "MT-K8S-tenant1-app1-engineer",
			prefix:           "MT-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "tenant1-app1",
			expectedRole:     "engineer",
			expectError:      false,
		},
		{
			name:             "Long prefix (MT-K8S-DEV-K8S)",
			permissionString: "MT-K8S-DEV-K8S-staging-app-admin",
			prefix:           "MT-K8S-DEV-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "staging-app",
			expectedRole:     "admin",
			expectError:      false,
		},

		// Valid cases - Longest role match (important!)
		{
			name:             "Longest role match - 'read-only' vs 'only'",
			permissionString: "COMPANY-K8S-app-read-only",
			prefix:           "COMPANY-K8S",
			roleMapping: map[string]string{
				"read-only": "view",
				"only":      "some-other-role",
			},
			expectedNS:   "app",
			expectedRole: "read-only", // Should match "read-only", not "only"
			expectError:  false,
		},
		{
			name:             "Namespace contains role name as substring",
			permissionString: "COMPANY-K8S-admin-dashboard-admin",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "admin-dashboard",
			expectedRole:     "admin", // Last "admin" is the role
			expectError:      false,
		},
		{
			name:             "Role name appears multiple times",
			permissionString: "COMPANY-K8S-viewer-app-viewer",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "viewer-app",
			expectedRole:     "viewer", // Last occurrence is the role
			expectError:      false,
		},

		// Valid cases - Different roles
		{
			name:             "Engineer role",
			permissionString: "COMPANY-K8S-project1-engineer",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "project1",
			expectedRole:     "engineer",
			expectError:      false,
		},
		{
			name:             "Viewer role",
			permissionString: "COMPANY-K8S-project2-viewer",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "project2",
			expectedRole:     "viewer",
			expectError:      false,
		},
		{
			name:             "Developer role",
			permissionString: "COMPANY-K8S-dev-env-developer",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "dev-env",
			expectedRole:     "developer",
			expectError:      false,
		},

		// Error cases - Wrong prefix
		{
			name:             "Wrong prefix",
			permissionString: "COMPANY-K8S-app-admin",
			prefix:           "WRONG-PREFIX",
			roleMapping:      standardRoleMapping,
			expectedNS:       "",
			expectedRole:     "",
			expectError:      true,
		},
		{
			name:             "Missing prefix hyphen",
			permissionString: "COMPANYK8S-app-admin", // No hyphen after prefix
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "",
			expectedRole:     "",
			expectError:      true,
		},

		// Error cases - Missing role
		{
			name:             "Role not in mapping",
			permissionString: "COMPANY-K8S-app-unknown-role",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "",
			expectedRole:     "",
			expectError:      true,
		},
		{
			name:             "No role specified",
			permissionString: "COMPANY-K8S-app",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "",
			expectedRole:     "",
			expectError:      true,
		},

		// Error cases - Empty namespace
		{
			name:             "Empty namespace",
			permissionString: "COMPANY-K8S-admin", // No namespace, just prefix and role
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "",
			expectedRole:     "",
			expectError:      true,
		},

		// Error cases - Empty inputs
		{
			name:             "Empty permission string",
			permissionString: "",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "",
			expectedRole:     "",
			expectError:      true,
		},
		{
			name:             "Empty prefix",
			permissionString: "COMPANY-K8S-app-admin",
			prefix:           "",
			roleMapping:      standardRoleMapping,
			expectedNS:       "",
			expectedRole:     "",
			expectError:      true,
		},
		{
			name:             "Empty role mapping",
			permissionString: "COMPANY-K8S-app-admin",
			prefix:           "COMPANY-K8S",
			roleMapping:      map[string]string{},
			expectedNS:       "",
			expectedRole:     "",
			expectError:      true,
		},

		// Edge cases - Complex real-world scenarios
		{
			name:             "Complex namespace from ConfigMap example",
			permissionString: "COMPANY-K8S-test-namespace-v2-engineer",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "test-namespace-v2",
			expectedRole:     "engineer",
			expectError:      false,
		},
		{
			name:             "Namespace with version suffix",
			permissionString: "COMPANY-K8S-app-v1-0-1-admin",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "app-v1-0-1",
			expectedRole:     "admin",
			expectError:      false,
		},
		{
			name:             "Very long namespace",
			permissionString: "COMPANY-K8S-this-is-a-very-long-namespace-name-with-many-hyphens-and-segments-admin",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "this-is-a-very-long-namespace-name-with-many-hyphens-and-segments",
			expectedRole:     "admin",
			expectError:      false,
		},

		// Edge cases - Single character elements
		{
			name:             "Single character namespace",
			permissionString: "COMPANY-K8S-a-admin",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "a",
			expectedRole:     "admin",
			expectError:      false,
		},

		// Edge cases - Numbers in namespace
		{
			name:             "Namespace starts with number",
			permissionString: "COMPANY-K8S-123-app-admin",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "123-app",
			expectedRole:     "admin",
			expectError:      false,
		},
		{
			name:             "Namespace all numbers",
			permissionString: "COMPANY-K8S-12345-admin",
			prefix:           "COMPANY-K8S",
			roleMapping:      standardRoleMapping,
			expectedNS:       "12345",
			expectedRole:     "admin",
			expectError:      false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ns, role, err := r.parsePermissionString(tt.permissionString, tt.prefix, tt.roleMapping)

			// Check error expectation
			if tt.expectError {
				if err == nil {
					t.Errorf("Expected error but got none")
				}
				return
			}

			// Check for unexpected error
			if err != nil {
				t.Errorf("Unexpected error: %v", err)
				return
			}

			// Check namespace
			if ns != tt.expectedNS {
				t.Errorf("Expected namespace %q, got %q", tt.expectedNS, ns)
			}

			// Check role
			if role != tt.expectedRole {
				t.Errorf("Expected role %q, got %q", tt.expectedRole, role)
			}
		})
	}
}

// TestParsePermissionStringWithPrefixes tests prefix matching with multiple prefixes
func TestParsePermissionStringWithPrefixes(t *testing.T) {
	r := &PermissionBinderReconciler{}

	roleMapping := map[string]string{
		"admin":    "admin",
		"engineer": "edit",
		"viewer":   "view",
	}

	tests := []struct {
		name             string
		permissionString string
		prefixes         []string
		expectedNS       string
		expectedRole     string
		expectedPrefix   string
		expectError      bool
	}{
		{
			name:             "Single prefix match",
			permissionString: "COMPANY-K8S-app-admin",
			prefixes:         []string{"COMPANY-K8S"},
			expectedNS:       "app",
			expectedRole:     "admin",
			expectedPrefix:   "COMPANY-K8S",
			expectError:      false,
		},
		{
			name:             "Multiple prefixes - first matches",
			permissionString: "COMPANY-K8S-app-admin",
			prefixes:         []string{"COMPANY-K8S", "MT-K8S"},
			expectedNS:       "app",
			expectedRole:     "admin",
			expectedPrefix:   "COMPANY-K8S",
			expectError:      false,
		},
		{
			name:             "Multiple prefixes - second matches",
			permissionString: "MT-K8S-tenant1-app-engineer",
			prefixes:         []string{"COMPANY-K8S", "MT-K8S"},
			expectedNS:       "tenant1-app",
			expectedRole:     "engineer",
			expectedPrefix:   "MT-K8S",
			expectError:      false,
		},
		{
			name:             "Longest prefix wins (overlapping prefixes)",
			permissionString: "MT-K8S-DEV-K8S-staging-app-admin",
			prefixes:         []string{"MT-K8S", "MT-K8S-DEV-K8S"}, // Longer should match first
			expectedNS:       "staging-app",
			expectedRole:     "admin",
			expectedPrefix:   "MT-K8S-DEV-K8S", // Should match longest prefix
			expectError:      false,
		},
		{
			name:             "Longest prefix wins (reverse order)",
			permissionString: "MT-K8S-DEV-K8S-staging-app-admin",
			prefixes:         []string{"MT-K8S-DEV-K8S", "MT-K8S"}, // Order shouldn't matter
			expectedNS:       "staging-app",
			expectedRole:     "admin",
			expectedPrefix:   "MT-K8S-DEV-K8S",
			expectError:      false,
		},
		{
			name:             "No prefix matches",
			permissionString: "UNKNOWN-PREFIX-app-admin",
			prefixes:         []string{"COMPANY-K8S", "MT-K8S"},
			expectedNS:       "",
			expectedRole:     "",
			expectedPrefix:   "",
			expectError:      true,
		},
		{
			name:             "Empty prefix list",
			permissionString: "COMPANY-K8S-app-admin",
			prefixes:         []string{},
			expectedNS:       "",
			expectedRole:     "",
			expectedPrefix:   "",
			expectError:      true,
		},
		{
			name:             "Three prefixes - longest matches",
			permissionString: "MT-K8S-DEV-K8S-LONG-staging-app-admin",
			prefixes:         []string{"MT-K8S", "MT-K8S-DEV-K8S", "MT-K8S-DEV-K8S-LONG"},
			expectedNS:       "staging-app",
			expectedRole:     "admin",
			expectedPrefix:   "MT-K8S-DEV-K8S-LONG",
			expectError:      false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ns, role, prefix, err := r.parsePermissionStringWithPrefixes(tt.permissionString, tt.prefixes, roleMapping)

			// Check error expectation
			if tt.expectError {
				if err == nil {
					t.Errorf("Expected error but got none")
				}
				return
			}

			// Check for unexpected error
			if err != nil {
				t.Errorf("Unexpected error: %v", err)
				return
			}

			// Check namespace
			if ns != tt.expectedNS {
				t.Errorf("Expected namespace %q, got %q", tt.expectedNS, ns)
			}

			// Check role
			if role != tt.expectedRole {
				t.Errorf("Expected role %q, got %q", tt.expectedRole, role)
			}

			// Check matched prefix
			if prefix != tt.expectedPrefix {
				t.Errorf("Expected prefix %q, got %q", tt.expectedPrefix, prefix)
			}
		})
	}
}

// BenchmarkParsePermissionString - Performance benchmarks
func BenchmarkParsePermissionString(b *testing.B) {
	r := &PermissionBinderReconciler{}
	roleMapping := map[string]string{
		"admin":     "admin",
		"engineer":  "edit",
		"viewer":    "view",
		"read-only": "view",
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _, _ = r.parsePermissionString("COMPANY-K8S-project-123-admin", "COMPANY-K8S", roleMapping)
	}
}

func BenchmarkParsePermissionString_Complex(b *testing.B) {
	r := &PermissionBinderReconciler{}
	roleMapping := map[string]string{
		"admin":     "admin",
		"engineer":  "edit",
		"viewer":    "view",
		"read-only": "view",
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _, _ = r.parsePermissionString("MT-K8S-DEV-K8S-staging-app-with-many-hyphens-v2-engineer", "MT-K8S-DEV-K8S", roleMapping)
	}
}

func BenchmarkParsePermissionStringWithPrefixes(b *testing.B) {
	r := &PermissionBinderReconciler{}
	prefixes := []string{"COMPANY-K8S", "MT-K8S", "MT-K8S-DEV-K8S"}
	roleMapping := map[string]string{
		"admin":    "admin",
		"engineer": "edit",
		"viewer":   "view",
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _, _, _ = r.parsePermissionStringWithPrefixes("MT-K8S-DEV-K8S-staging-app-admin", prefixes, roleMapping)
	}
}

