package controller

import (
	"testing"
)

// TestParseCN tests the ParseCN function
func TestParseCN(t *testing.T) {
	tests := []struct {
		name              string
		cn                string
		expectedGroupName string
		expectedPath      string
		expectedFullDN    string
		expectError       bool
	}{
		// Valid cases - Standard LDAP DN formats
		{
			name:              "Standard LDAP group",
			cn:                "CN=MT-K8S-tenant1-project1-engineer,OU=Tenant1,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "MT-K8S-tenant1-project1-engineer",
			expectedPath:      "OU=Tenant1,OU=Kubernetes,DC=example,DC=com",
			expectedFullDN:    "CN=MT-K8S-tenant1-project1-engineer,OU=Tenant1,OU=Kubernetes,DC=example,DC=com",
			expectError:       false,
		},
		{
			name:              "Simple group with one OU",
			cn:                "CN=COMPANY-K8S-app-admin,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "COMPANY-K8S-app-admin",
			expectedPath:      "OU=Kubernetes,DC=example,DC=com",
			expectedFullDN:    "CN=COMPANY-K8S-app-admin,OU=Kubernetes,DC=example,DC=com",
			expectError:       false,
		},
		{
			name:              "Multiple OUs",
			cn:                "CN=MT-K8S-project-viewer,OU=Team1,OU=Projects,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "MT-K8S-project-viewer",
			expectedPath:      "OU=Team1,OU=Projects,OU=Kubernetes,DC=example,DC=com",
			expectedFullDN:    "CN=MT-K8S-project-viewer,OU=Team1,OU=Projects,OU=Kubernetes,DC=example,DC=com",
			expectError:       false,
		},

		// Valid cases - Group names with special characters
		{
			name:              "Group name with underscores",
			cn:                "CN=DD_0000-K8S-123-admin,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "DD_0000-K8S-123-admin",
			expectedPath:      "OU=Kubernetes,DC=example,DC=com",
			expectedFullDN:    "CN=DD_0000-K8S-123-admin,OU=Kubernetes,DC=example,DC=com",
			expectError:       false,
		},
		{
			name:              "Group name with numbers",
			cn:                "CN=COMPANY-K8S-project-123-engineer,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "COMPANY-K8S-project-123-engineer",
			expectedPath:      "OU=Kubernetes,DC=example,DC=com",
			expectedFullDN:    "CN=COMPANY-K8S-project-123-engineer,OU=Kubernetes,DC=example,DC=com",
			expectError:       false,
		},
		{
			name:              "Group name with dots",
			cn:                "CN=app.v1.0-admin,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "app.v1.0-admin",
			expectedPath:      "OU=Kubernetes,DC=example,DC=com",
			expectedFullDN:    "CN=app.v1.0-admin,OU=Kubernetes,DC=example,DC=com",
			expectError:       false,
		},

		// Valid cases - Complex paths
		{
			name:              "Complex path with multiple DCs",
			cn:                "CN=test-group,OU=IT,OU=Platform,DC=corp,DC=example,DC=com",
			expectedGroupName: "test-group",
			expectedPath:      "OU=IT,OU=Platform,DC=corp,DC=example,DC=com",
			expectedFullDN:    "CN=test-group,OU=IT,OU=Platform,DC=corp,DC=example,DC=com",
			expectError:       false,
		},
		{
			name:              "Path with single DC",
			cn:                "CN=simple-group,OU=Users,DC=local",
			expectedGroupName: "simple-group",
			expectedPath:      "OU=Users,DC=local",
			expectedFullDN:    "CN=simple-group,OU=Users,DC=local",
			expectError:       false,
		},

		// Valid cases - Minimal DNs
		{
			name:              "Minimal DN (CN + DC only)",
			cn:                "CN=group1,DC=example",
			expectedGroupName: "group1",
			expectedPath:      "DC=example",
			expectedFullDN:    "CN=group1,DC=example",
			expectError:       false,
		},

		// Valid cases - Long group names
		{
			name:              "Very long group name",
			cn:                "CN=MT-K8S-DEV-K8S-staging-app-with-very-long-name-engineer,OU=Dev,DC=example,DC=com",
			expectedGroupName: "MT-K8S-DEV-K8S-staging-app-with-very-long-name-engineer",
			expectedPath:      "OU=Dev,DC=example,DC=com",
			expectedFullDN:    "CN=MT-K8S-DEV-K8S-staging-app-with-very-long-name-engineer,OU=Dev,DC=example,DC=com",
			expectError:       false,
		},

		// Error cases - Invalid format
		{
			name:              "Missing CN prefix",
			cn:                "group-name,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "",
			expectedPath:      "",
			expectedFullDN:    "",
			expectError:       true,
		},
		{
			name:              "No comma after CN",
			cn:                "CN=group-name",
			expectedGroupName: "",
			expectedPath:      "",
			expectedFullDN:    "",
			expectError:       true,
		},
		{
			name:              "Empty string",
			cn:                "",
			expectedGroupName: "",
			expectedPath:      "",
			expectedFullDN:    "",
			expectError:       true,
		},
		{
			name:              "Only CN= without value",
			cn:                "CN=,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "",
			expectedPath:      "",
			expectedFullDN:    "",
			expectError:       true, // Regex [^,]+ requires at least one character
		},

		// Error cases - Lowercase cn
		{
			name:              "Lowercase cn (should fail)",
			cn:                "cn=group-name,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "",
			expectedPath:      "",
			expectedFullDN:    "",
			expectError:       true, // Regex requires uppercase CN=
		},

		// Edge cases - Spaces
		{
			name:              "Group name with spaces",
			cn:                "CN=Group With Spaces,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "Group With Spaces",
			expectedPath:      "OU=Kubernetes,DC=example,DC=com",
			expectedFullDN:    "CN=Group With Spaces,OU=Kubernetes,DC=example,DC=com",
			expectError:       false,
		},
		{
			name:              "Path with spaces",
			cn:                "CN=test-group,OU=Organizational Unit,DC=example,DC=com",
			expectedGroupName: "test-group",
			expectedPath:      "OU=Organizational Unit,DC=example,DC=com",
			expectedFullDN:    "CN=test-group,OU=Organizational Unit,DC=example,DC=com",
			expectError:       false,
		},

		// Edge cases - Special characters in group name
		{
			name:              "Group name with equals sign",
			cn:                "CN=app=test-admin,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "app=test-admin",
			expectedPath:      "OU=Kubernetes,DC=example,DC=com",
			expectedFullDN:    "CN=app=test-admin,OU=Kubernetes,DC=example,DC=com",
			expectError:       false,
		},

		// Real-world examples
		{
			name:              "Example from documentation",
			cn:                "CN=MT-K8S-tenant1-app1-engineer,OU=Tenant1,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "MT-K8S-tenant1-app1-engineer",
			expectedPath:      "OU=Tenant1,OU=Kubernetes,DC=example,DC=com",
			expectedFullDN:    "CN=MT-K8S-tenant1-app1-engineer,OU=Tenant1,OU=Kubernetes,DC=example,DC=com",
			expectError:       false,
		},
		{
			name:              "Development environment",
			cn:                "CN=MT-K8S-DEV-K8S-staging-app-engineer,OU=Dev,OU=Kubernetes,DC=example,DC=com",
			expectedGroupName: "MT-K8S-DEV-K8S-staging-app-engineer",
			expectedPath:      "OU=Dev,OU=Kubernetes,DC=example,DC=com",
			expectedFullDN:    "CN=MT-K8S-DEV-K8S-staging-app-engineer,OU=Dev,OU=Kubernetes,DC=example,DC=com",
			expectError:       false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := ParseCN(tt.cn)

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

			// Verify result is not nil
			if result == nil {
				t.Errorf("Expected result but got nil")
				return
			}

			// Check group name
			if result.GroupName != tt.expectedGroupName {
				t.Errorf("Expected GroupName %q, got %q", tt.expectedGroupName, result.GroupName)
			}

			// Check path
			if result.Path != tt.expectedPath {
				t.Errorf("Expected Path %q, got %q", tt.expectedPath, result.Path)
			}

			// Check full DN
			if result.FullDN != tt.expectedFullDN {
				t.Errorf("Expected FullDN %q, got %q", tt.expectedFullDN, result.FullDN)
			}
		})
	}
}

// BenchmarkParseCN - Performance benchmark
func BenchmarkParseCN(b *testing.B) {
	cn := "CN=MT-K8S-tenant1-project1-engineer,OU=Tenant1,OU=Kubernetes,DC=example,DC=com"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = ParseCN(cn)
	}
}

func BenchmarkParseCN_Complex(b *testing.B) {
	cn := "CN=MT-K8S-DEV-K8S-staging-app-with-very-long-name-engineer,OU=Dev,OU=Projects,OU=Kubernetes,OU=Platform,DC=corp,DC=example,DC=com"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = ParseCN(cn)
	}
}
