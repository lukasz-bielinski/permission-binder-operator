package controller

import (
	"testing"
)

// TestExtractCNFromDN tests the extractCNFromDN function with various DN formats
func TestExtractCNFromDN(t *testing.T) {
	// Create a reconciler instance for testing
	r := &PermissionBinderReconciler{}

	tests := []struct {
		name        string
		dn          string
		expectedCN  string
		expectError bool
	}{
		// Valid cases - Standard LDAP DN formats
		{
			name:        "Standard LDAP DN",
			dn:          "CN=COMPANY-K8S-app-admin,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-app-admin",
			expectError: false,
		},
		{
			name:        "DN with multiple OUs",
			dn:          "CN=MT-K8S-project-viewer,OU=Team1,OU=Projects,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "MT-K8S-project-viewer",
			expectError: false,
		},
		{
			name:        "DN with underscores in CN",
			dn:          "CN=DD_0000-K8S-123-Cluster-admin,OU=Openshift-123,DC=example,DC=com",
			expectedCN:  "DD_0000-K8S-123-Cluster-admin",
			expectError: false,
		},
		{
			name:        "DN with spaces in CN (should be trimmed)",
			dn:          "CN= COMPANY-K8S-app-admin ,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-app-admin",
			expectError: false,
		},
		{
			name:        "DN with trailing spaces",
			dn:          "CN=COMPANY-K8S-app-admin   ,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-app-admin",
			expectError: false,
		},
		{
			name:        "DN with leading spaces",
			dn:          "CN=   COMPANY-K8S-app-admin,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-app-admin",
			expectError: false,
		},

		// Valid cases - CN at different positions
		{
			name:        "CN at the beginning",
			dn:          "CN=COMPANY-K8S-app-admin,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-app-admin",
			expectError: false,
		},
		{
			name:        "CN after other attributes (should find first CN)",
			dn:          "OU=Kubernetes,CN=COMPANY-K8S-app-admin,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-app-admin",
			expectError: false,
		},

		// Valid cases - No comma after CN (last element)
		{
			name:        "CN without trailing comma",
			dn:          "CN=COMPANY-K8S-app-admin",
			expectedCN:  "COMPANY-K8S-app-admin",
			expectError: false,
		},
		{
			name:        "CN as last element with other attributes before",
			dn:          "OU=Kubernetes,DC=example,CN=COMPANY-K8S-app-admin",
			expectedCN:  "COMPANY-K8S-app-admin",
			expectError: false,
		},

		// Valid cases - Special characters in CN
		{
			name:        "CN with hyphens",
			dn:          "CN=COMPANY-K8S-app-with-many-hyphens-admin,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-app-with-many-hyphens-admin",
			expectError: false,
		},
		{
			name:        "CN with numbers",
			dn:          "CN=COMPANY-K8S-project-123-admin,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-project-123-admin",
			expectError: false,
		},
		{
			name:        "CN with dots",
			dn:          "CN=COMPANY-K8S-app.v1.0-admin,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-app.v1.0-admin",
			expectError: false,
		},

		// Valid cases - Multiple prefixes
		{
			name:        "Multi-tenant prefix (MT-K8S)",
			dn:          "CN=MT-K8S-tenant1-app1-engineer,OU=Tenant1,DC=example,DC=com",
			expectedCN:  "MT-K8S-tenant1-app1-engineer",
			expectError: false,
		},
		{
			name:        "Development prefix (MT-K8S-DEV-K8S)",
			dn:          "CN=MT-K8S-DEV-K8S-staging-app-engineer,OU=Dev,DC=example,DC=com",
			expectedCN:  "MT-K8S-DEV-K8S-staging-app-engineer",
			expectError: false,
		},

		// Error cases - Missing CN
		{
			name:        "No CN in DN",
			dn:          "OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "",
			expectError: true,
		},
		{
			name:        "Empty DN",
			dn:          "",
			expectedCN:  "",
			expectError: true,
		},
		{
			name:        "DN with only spaces",
			dn:          "   ",
			expectedCN:  "",
			expectError: true,
		},

		// Error cases - Invalid CN format
		{
			name:        "CN= without value",
			dn:          "CN=,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "",
			expectError: false, // Empty CN is valid (will be trimmed to "")
		},
		{
			name:        "CN= with only spaces",
			dn:          "CN=   ,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "",
			expectError: false, // Spaces are trimmed, resulting in ""
		},

		// Edge cases - Case sensitivity
		{
			name:        "Lowercase cn (should not match)",
			dn:          "cn=COMPANY-K8S-app-admin,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "",
			expectError: true, // Function looks for uppercase CN=
		},
		{
			name:        "Mixed case CN",
			dn:          "Cn=COMPANY-K8S-app-admin,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "",
			expectError: true, // Function looks for uppercase CN=
		},

		// Edge cases - Multiple CNs
		{
			name:        "Multiple CNs (should return first)",
			dn:          "CN=FIRST-K8S-app-admin,CN=SECOND-K8S-app-viewer,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "FIRST-K8S-app-admin",
			expectError: false,
		},

		// Edge cases - Complex real-world examples
		{
			name:        "Complex DN from Active Directory",
			dn:          "CN=COMPANY-K8S-project1-engineer,OU=Kubernetes,OU=Platform,OU=IT,DC=corp,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-project1-engineer",
			expectError: false,
		},
		{
			name:        "DN with escaped characters (comma in CN value)",
			dn:          "CN=COMPANY-K8S-app\\,test-admin,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-app\\", // Will split at first comma (not handling escapes)
			expectError: false,                // Current implementation doesn't handle escaped commas
		},

		// Real examples from documentation
		{
			name:        "Example from ConfigMap",
			dn:          "CN=COMPANY-K8S-project1-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-project1-engineer",
			expectError: false,
		},
		{
			name:        "Example with long prefix",
			dn:          "CN=MT-K8S-DEV-K8S-staging-app-engineer,OU=Dev,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "MT-K8S-DEV-K8S-staging-app-engineer",
			expectError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cn, err := r.extractCNFromDN(tt.dn)

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

			// Check CN value
			if cn != tt.expectedCN {
				t.Errorf("Expected CN %q, got %q", tt.expectedCN, cn)
			}
		})
	}
}

// TestExtractCNFromDN_Benchmarks - Performance benchmarks
func BenchmarkExtractCNFromDN(b *testing.B) {
	r := &PermissionBinderReconciler{}
	dn := "CN=COMPANY-K8S-project1-engineer,OU=Kubernetes,OU=Platform,DC=example,DC=com"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = r.extractCNFromDN(dn)
	}
}

func BenchmarkExtractCNFromDN_Complex(b *testing.B) {
	r := &PermissionBinderReconciler{}
	dn := "CN=MT-K8S-DEV-K8S-staging-app-with-very-long-name-engineer,OU=Dev,OU=Kubernetes,OU=Platform,OU=IT,DC=corp,DC=example,DC=com"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = r.extractCNFromDN(dn)
	}
}

// TestExtractCNFromDN_TableDrivenEdgeCases - Additional edge cases
func TestExtractCNFromDN_TableDrivenEdgeCases(t *testing.T) {
	r := &PermissionBinderReconciler{}

	edgeCases := []struct {
		name        string
		dn          string
		expectedCN  string
		expectError bool
		description string
	}{
		{
			name:        "Very long CN value",
			dn:          "CN=COMPANY-K8S-this-is-a-very-long-namespace-name-that-might-exceed-kubernetes-limits-but-should-still-be-extracted-correctly-admin,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-this-is-a-very-long-namespace-name-that-might-exceed-kubernetes-limits-but-should-still-be-extracted-correctly-admin",
			expectError: false,
			description: "Should handle very long CN values",
		},
		{
			name:        "CN with Unicode characters",
			dn:          "CN=COMPANY-K8S-app-ąćęłńóśźż-admin,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-app-ąćęłńóśźż-admin",
			expectError: false,
			description: "Should handle Unicode characters",
		},
		{
			name:        "Empty string between commas",
			dn:          "CN=COMPANY-K8S-app-admin,,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-app-admin",
			expectError: false,
			description: "Should handle empty attributes gracefully",
		},
		{
			name:        "CN with equals sign in value",
			dn:          "CN=COMPANY-K8S-app=test-admin,OU=Kubernetes,DC=example,DC=com",
			expectedCN:  "COMPANY-K8S-app=test-admin",
			expectError: false,
			description: "Should handle equals sign in CN value",
		},
	}

	for _, tc := range edgeCases {
		t.Run(tc.name, func(t *testing.T) {
			cn, err := r.extractCNFromDN(tc.dn)

			if tc.expectError && err == nil {
				t.Errorf("%s: Expected error but got none", tc.description)
			}

			if !tc.expectError && err != nil {
				t.Errorf("%s: Unexpected error: %v", tc.description, err)
			}

			if cn != tc.expectedCN {
				t.Errorf("%s: Expected CN %q, got %q", tc.description, tc.expectedCN, cn)
			}
		})
	}
}

