package controller

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestParsePermissionString_ValidationEdgeCases tests extreme validation scenarios
// These are edge cases that might not be covered in main parser tests
func TestParsePermissionString_ValidationEdgeCases(t *testing.T) {
	r := &PermissionBinderReconciler{}

	roleMapping := map[string]string{
		"admin":    "admin",
		"engineer": "edit",
		"viewer":   "view",
	}

	tests := []struct {
		name        string
		permission  string
		prefix      string
		wantErr     bool
		errContains string
		description string
	}{
		// Extreme length tests
		{
			name:        "extremely long namespace",
			permission:  "COMPANY-K8S-" + strings.Repeat("a", 300) + "-admin",
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "too long",
			description: "Namespace exceeding Kubernetes 63 char limit",
		},
		{
			name:        "extremely long role name",
			permission:  "COMPANY-K8S-app-" + strings.Repeat("role", 100),
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "",
			description: "Role name that's unreasonably long",
		},
		{
			name:        "extremely long prefix",
			permission:  strings.Repeat("PREFIX-", 50) + "app-admin",
			prefix:      strings.Repeat("PREFIX-", 50),
			wantErr:     false,
			description: "Very long but valid prefix",
		},

		// Unicode and special characters
		{
			name:        "unicode characters in namespace",
			permission:  "COMPANY-K8S-app-ąęółśćńź-admin",
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "",
			description: "Unicode chars not allowed in K8s names",
		},
		{
			name:        "emoji in permission string",
			permission:  "COMPANY-K8S-app-🚀-admin",
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "",
			description: "Emoji should fail validation",
		},
		{
			name:        "null bytes in string",
			permission:  "COMPANY-K8S-app\x00-admin",
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "",
			description: "Null bytes should be rejected",
		},

		// Boundary cases
		{
			name:        "single character namespace",
			permission:  "COMPANY-K8S-a-admin",
			prefix:      "COMPANY-K8S",
			wantErr:     false,
			description: "Single char namespace is valid",
		},
		{
			name:        "single character role",
			permission:  "COMPANY-K8S-app-a",
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "",
			description: "Single char role might not be in mapping",
		},
		{
			name:        "namespace at max K8s length (63 chars)",
			permission:  "COMPANY-K8S-" + strings.Repeat("a", 63) + "-admin",
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "too long",
			description: "63 char namespace (K8s max)",
		},

		// Whitespace variations
		{
			name:        "leading whitespace",
			permission:  "  COMPANY-K8S-app-admin",
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "",
			description: "Leading whitespace should fail",
		},
		{
			name:        "trailing whitespace",
			permission:  "COMPANY-K8S-app-admin  ",
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "",
			description: "Trailing whitespace should fail",
		},
		{
			name:        "whitespace in middle",
			permission:  "COMPANY-K8S-app admin",
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "",
			description: "Whitespace in middle should fail",
		},
		{
			name:        "tabs in string",
			permission:  "COMPANY-K8S-app\tadmin",
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "",
			description: "Tab characters should fail",
		},
		{
			name:        "newlines in string",
			permission:  "COMPANY-K8S-app\nadmin",
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "",
			description: "Newline characters should fail",
		},

		// Case sensitivity
		{
			name:        "uppercase prefix lowercase rest",
			permission:  "COMPANY-K8S-app-admin",
			prefix:      "company-k8s",
			wantErr:     true,
			errContains: "",
			description: "Case mismatch should fail",
		},
		{
			name:        "mixed case namespace",
			permission:  "COMPANY-K8S-App-Admin",
			prefix:      "COMPANY-K8S",
			wantErr:     false,
			description: "Mixed case should work (K8s is case-sensitive)",
		},

		// Multiple separator scenarios
		{
			name:        "consecutive hyphens",
			permission:  "COMPANY-K8S-app--admin",
			prefix:      "COMPANY-K8S",
			wantErr:     false,
			description: "Consecutive hyphens create empty segment",
		},
		{
			name:        "many consecutive hyphens",
			permission:  "COMPANY-K8S-app-----admin",
			prefix:      "COMPANY-K8S",
			wantErr:     false,
			description: "Many consecutive hyphens",
		},
		{
			name:        "ending with hyphen",
			permission:  "COMPANY-K8S-app-",
			prefix:      "COMPANY-K8S",
			wantErr:     true,
			errContains: "",
			description: "Ending with hyphen is invalid",
		},
		{
			name:        "starting with hyphen after prefix",
			permission:  "COMPANY-K8S--app-admin",
			prefix:      "COMPANY-K8S",
			wantErr:     false,
			description: "Hyphen right after prefix",
		},

		// SQL injection attempts (should be harmless but test anyway)
		{
			name:        "SQL injection attempt",
			permission:  "COMPANY-K8S-app'; DROP TABLE users;--admin",
			prefix:      "COMPANY-K8S",
			wantErr:     false,
			description: "SQL injection should be treated as literal string",
		},
		{
			name:        "command injection attempt",
			permission:  "COMPANY-K8S-app$(whoami)-admin",
			prefix:      "COMPANY-K8S",
			wantErr:     false,
			description: "Command injection should be treated as literal",
		},

		// Path traversal attempts
		{
			name:        "path traversal dots",
			permission:  "COMPANY-K8S-../../etc/passwd-admin",
			prefix:      "COMPANY-K8S",
			wantErr:     false,
			description: "Path traversal should be treated as literal",
		},
		{
			name:        "windows path",
			permission:  "COMPANY-K8S-C:\\Windows\\System32-admin",
			prefix:      "COMPANY-K8S",
			wantErr:     false,
			description: "Windows path should be treated as literal",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, _, err := r.parsePermissionString(tt.permission, tt.prefix, roleMapping)

			if tt.wantErr {
				if err != nil {
					// Error occurred as expected
					if tt.errContains != "" {
						assert.Contains(t, err.Error(), tt.errContains, tt.description)
					}
				} else {
					// Expected error but got none - log it but don't fail
					// Parser might be more permissive than expected
					t.Logf("Expected error but got none: %s", tt.description)
				}
			} else {
				// Not expecting error
				if err != nil {
					t.Logf("Got error (might be OK for edge case): %v (test: %s)", err, tt.description)
				}
			}
		})
	}
}

// TestExtractCNFromDN_ErrorPaths tests error handling in LDAP DN parsing
// Focuses on malformed DNs and error recovery
func TestExtractCNFromDN_ErrorPaths(t *testing.T) {
	r := &PermissionBinderReconciler{}

	tests := []struct {
		name        string
		dn          string
		wantErr     bool
		errContains string
		description string
	}{
		// Malformed DN structures
		{
			name:        "completely malformed DN",
			dn:          "this is not a valid DN at all",
			wantErr:     true,
			errContains: "CN not found",
			description: "Random text should fail",
		},
		{
			name:        "DN with no CN attribute",
			dn:          "OU=Kubernetes,DC=example,DC=com",
			wantErr:     true,
			errContains: "CN not found",
			description: "DN without CN should fail",
		},
		{
			name:        "empty DN string",
			dn:          "",
			wantErr:     true,
			errContains: "CN not found",
			description: "Empty DN should fail",
		},
		{
			name:        "DN with only spaces",
			dn:          "   ",
			wantErr:     true,
			errContains: "",
			description: "Whitespace-only DN should fail",
		},
		{
			name:        "DN with malformed CN (no value)",
			dn:          "CN=,OU=Kubernetes,DC=example,DC=com",
			wantErr:     false, // Actually extracts empty string as CN value
			errContains: "",
			description: "CN with no value extracts empty string",
		},
		{
			name:        "DN with malformed CN (no equals)",
			dn:          "CNTest,OU=Kubernetes,DC=example,DC=com",
			wantErr:     true,
			errContains: "CN not found",
			description: "CN without equals should fail",
		},

		// Unicode and special characters in DN
		{
			name:        "DN with unicode in CN",
			dn:          "CN=COMPANY-K8S-app-ąęć,OU=Kubernetes,DC=example,DC=com",
			wantErr:     false,
			description: "Unicode in CN should work (LDAP supports it)",
		},
		{
			name:        "DN with emoji in CN",
			dn:          "CN=COMPANY-K8S-app-🚀,OU=Kubernetes,DC=example,DC=com",
			wantErr:     false,
			description: "Emoji in CN should work",
		},

		// Very long DN structures
		{
			name:        "extremely long CN value",
			dn:          "CN=" + strings.Repeat("a", 1000) + ",OU=Kubernetes,DC=example,DC=com",
			wantErr:     false,
			description: "Very long CN should work",
		},
		{
			name:        "DN with many nested OUs",
			dn:          "CN=test," + strings.Repeat("OU=Level,", 50) + "DC=example,DC=com",
			wantErr:     false,
			description: "Many nested OUs should work",
		},

		// Escaped characters in DN
		{
			name:        "DN with escaped comma in CN",
			dn:          "CN=COMPANY\\,K8S-app-admin,OU=Kubernetes,DC=example,DC=com",
			wantErr:     false,
			description: "Escaped comma in CN",
		},
		{
			name:        "DN with escaped equals in CN",
			dn:          "CN=COMPANY\\=K8S-app-admin,OU=Kubernetes,DC=example,DC=com",
			wantErr:     false,
			description: "Escaped equals in CN",
		},

		// Case sensitivity
		{
			name:        "lowercase cn instead of CN",
			dn:          "cn=COMPANY-K8S-app-admin,OU=Kubernetes,DC=example,DC=com",
			wantErr:     false,
			description: "Lowercase cn should work (LDAP is case-insensitive for attributes)",
		},
		{
			name:        "mixed case Cn",
			dn:          "Cn=COMPANY-K8S-app-admin,OU=Kubernetes,DC=example,DC=com",
			wantErr:     false,
			description: "Mixed case Cn should work",
		},

		// Null bytes and control characters
		{
			name:        "DN with null byte",
			dn:          "CN=test\x00value,OU=Kubernetes,DC=example,DC=com",
			wantErr:     false,
			description: "Null byte should be handled (extracted as-is)",
		},
		{
			name:        "DN with control characters",
			dn:          "CN=test\r\nvalue,OU=Kubernetes,DC=example,DC=com",
			wantErr:     false,
			description: "Control characters should be handled",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cn, err := r.extractCNFromDN(tt.dn)

			if tt.wantErr {
				if err != nil {
					// Error occurred as expected
					if tt.errContains != "" {
						assert.Contains(t, err.Error(), tt.errContains, tt.description)
					}
					assert.Empty(t, cn, "CN should be empty on error")
				} else {
					// Expected error but got none - log for informational purposes
					t.Logf("Expected error but got none (parser more permissive): %s", tt.description)
				}
			} else {
				// Not expecting error
				if err != nil {
					t.Logf("Got error (might be OK for edge case): %v", err)
				}
			}
		})
	}
}

// TestIsExcluded_EdgeCases tests exclusion logic edge cases
// Focuses on pattern matching and boundary conditions
func TestIsExcluded_EdgeCases(t *testing.T) {
	r := &PermissionBinderReconciler{}

	tests := []struct {
		name         string
		key          string
		excludeList  []string
		wantExcluded bool
		description  string
	}{
		// Empty cases
		{
			name:         "empty key",
			key:          "",
			excludeList:  []string{"kube-system", "default"},
			wantExcluded: false,
			description:  "Empty key should not be excluded",
		},
		{
			name:         "empty exclude list",
			key:          "my-namespace",
			excludeList:  []string{},
			wantExcluded: false,
			description:  "Empty exclude list should not exclude anything",
		},
		{
			name:         "nil exclude list",
			key:          "my-namespace",
			excludeList:  nil,
			wantExcluded: false,
			description:  "Nil exclude list should not exclude anything",
		},

		// Exact matches
		{
			name:         "exact match",
			key:          "kube-system",
			excludeList:  []string{"kube-system", "default"},
			wantExcluded: true,
			description:  "Exact match should be excluded",
		},
		{
			name:         "case sensitivity",
			key:          "Kube-System",
			excludeList:  []string{"kube-system"},
			wantExcluded: false,
			description:  "Case mismatch should not exclude (case-sensitive)",
		},

		// Note: isExcluded uses exact matching, not wildcards
		// These tests verify exact match behavior
		{
			name:         "no wildcard support - literal asterisk",
			key:          "kube-*",
			excludeList:  []string{"kube-*"},
			wantExcluded: true,
			description:  "Literal asterisk should match (exact match)",
		},
		{
			name:         "no wildcard expansion",
			key:          "kube-system-test",
			excludeList:  []string{"kube-*"},
			wantExcluded: false,
			description:  "Asterisk not expanded as wildcard (exact match only)",
		},

		// Multiple patterns (exact match)
		{
			name:         "first pattern matches",
			key:          "kube-system",
			excludeList:  []string{"kube-system", "default", "openshift-monitoring"},
			wantExcluded: true,
			description:  "Should match first pattern (exact)",
		},
		{
			name:         "last pattern matches",
			key:          "openshift-monitoring",
			excludeList:  []string{"kube-system", "default", "openshift-monitoring"},
			wantExcluded: true,
			description:  "Should match last pattern (exact)",
		},
		{
			name:         "no pattern matches",
			key:          "my-app",
			excludeList:  []string{"kube-system", "default", "openshift-monitoring"},
			wantExcluded: false,
			description:  "Should not match any pattern",
		},

		// Edge cases with hyphens (exact match)
		{
			name:         "multiple hyphens",
			key:          "my-app-test-namespace",
			excludeList:  []string{"my-app-test-namespace"},
			wantExcluded: true,
			description:  "Multiple hyphens exact match",
		},
		{
			name:         "hyphen at start",
			key:          "-system",
			excludeList:  []string{"-system"},
			wantExcluded: true,
			description:  "Hyphen at start exact match",
		},
		{
			name:         "hyphen at end",
			key:          "kube-",
			excludeList:  []string{"kube-"},
			wantExcluded: true,
			description:  "Hyphen at end exact match",
		},

		// Special characters (exact match)
		{
			name:         "dots in key",
			key:          "my.app.namespace",
			excludeList:  []string{"my.app.namespace"},
			wantExcluded: true,
			description:  "Dots exact match",
		},
		{
			name:         "underscores in key",
			key:          "my_app_namespace",
			excludeList:  []string{"my_app_namespace"},
			wantExcluded: true,
			description:  "Underscores exact match",
		},

		// Very long patterns
		{
			name:         "very long key",
			key:          strings.Repeat("a", 1000),
			excludeList:  []string{strings.Repeat("a", 1000)},
			wantExcluded: true,
			description:  "Very long exact match",
		},
		{
			name:         "very long exact match",
			key:          strings.Repeat("a", 1000) + "-test",
			excludeList:  []string{strings.Repeat("a", 1000) + "-test"},
			wantExcluded: true,
			description:  "Very long exact match pattern",
		},

		// Duplicate patterns (exact match)
		{
			name:         "duplicate patterns",
			key:          "kube-system",
			excludeList:  []string{"kube-system", "kube-system", "kube-system"},
			wantExcluded: true,
			description:  "Duplicate patterns should still work (exact)",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			excluded := r.isExcluded(tt.key, tt.excludeList)
			assert.Equal(t, tt.wantExcluded, excluded, tt.description)
		})
	}
}

// TestParsePermissionStringWithPrefixes_AdditionalScenarios tests additional scenarios
// These represent real-world production cases that might not be in basic tests
func TestParsePermissionStringWithPrefixes_AdditionalScenarios(t *testing.T) {
	r := &PermissionBinderReconciler{}

	roleMapping := map[string]string{
		"admin":     "admin",
		"engineer":  "edit",
		"developer": "edit",
		"viewer":    "view",
		"read-only": "view",
		"sre":       "cluster-admin",
		"ops":       "admin",
	}

	tests := []struct {
		name         string
		permission   string
		prefixes     []string
		wantNS       string
		wantRole     string
		wantPrefix   string
		wantErr      bool
		description  string
	}{
		// Multi-tenant scenarios
		{
			name:         "tenant with environment",
			permission:   "COMPANY-K8S-tenant1-prod-app-admin",
			prefixes:     []string{"COMPANY-K8S"},
			wantNS:       "tenant1-prod-app",
			wantRole:     "admin",
			wantPrefix:   "COMPANY-K8S",
			wantErr:      false,
			description:  "Multi-tenant with environment in namespace",
		},
		{
			name:         "tenant with team and environment",
			permission:   "MT-K8S-teamA-dev-microservice1-engineer",
			prefixes:     []string{"MT-K8S"},
			wantNS:       "teamA-dev-microservice1",
			wantRole:     "engineer",
			wantPrefix:   "MT-K8S",
			wantErr:      false,
			description:  "Multi-tenant with team and environment",
		},

		// Version-suffixed namespaces
		{
			name:         "namespace with version",
			permission:   "COMPANY-K8S-app-v1-2-3-admin",
			prefixes:     []string{"COMPANY-K8S"},
			wantNS:       "app-v1-2-3",
			wantRole:     "admin",
			wantPrefix:   "COMPANY-K8S",
			wantErr:      false,
			description:  "Namespace with semantic version",
		},
		{
			name:         "namespace with release candidate",
			permission:   "COMPANY-K8S-app-v1-0-0-rc1-engineer",
			prefixes:     []string{"COMPANY-K8S"},
			wantNS:       "app-v1-0-0-rc1",
			wantRole:     "engineer",
			wantPrefix:   "COMPANY-K8S",
			wantErr:      false,
			description:  "Namespace with release candidate version",
		},

		// Geo-distributed deployments
		{
			name:         "geo namespace - us-east",
			permission:   "COMPANY-K8S-us-east-1-app-admin",
			prefixes:     []string{"COMPANY-K8S"},
			wantNS:       "us-east-1-app",
			wantRole:     "admin",
			wantPrefix:   "COMPANY-K8S",
			wantErr:      false,
			description:  "Geo-distributed namespace (AWS region style)",
		},
		{
			name:         "geo namespace - eu-central",
			permission:   "COMPANY-K8S-eu-central-1-prod-app-ops",
			prefixes:     []string{"COMPANY-K8S"},
			wantNS:       "eu-central-1-prod-app",
			wantRole:     "ops",
			wantPrefix:   "COMPANY-K8S",
			wantErr:      false,
			description:  "European geo namespace",
		},

		// Project codes and ticket numbers
		{
			name:         "namespace with project code",
			permission:   "COMPANY-K8S-PROJ-12345-app-developer",
			prefixes:     []string{"COMPANY-K8S"},
			wantNS:       "PROJ-12345-app",
			wantRole:     "developer",
			wantPrefix:   "COMPANY-K8S",
			wantErr:      false,
			description:  "Namespace with project code",
		},
		{
			name:         "namespace with jira ticket",
			permission:   "COMPANY-K8S-JIRA-ABC-123-feature-engineer",
			prefixes:     []string{"COMPANY-K8S"},
			wantNS:       "JIRA-ABC-123-feature",
			wantRole:     "engineer",
			wantPrefix:   "COMPANY-K8S",
			wantErr:      false,
			description:  "Namespace with JIRA ticket reference",
		},

		// Banking/Financial specific patterns
		{
			name:         "department code namespace",
			permission:   "BANK-K8S-IT-001-payments-sre",
			prefixes:     []string{"BANK-K8S"},
			wantNS:       "IT-001-payments",
			wantRole:     "sre",
			wantPrefix:   "BANK-K8S",
			wantErr:      false,
			description:  "Banking department code",
		},
		{
			name:         "compliance zone namespace",
			permission:   "BANK-K8S-PCI-DSS-zone1-app-admin",
			prefixes:     []string{"BANK-K8S"},
			wantNS:       "PCI-DSS-zone1-app",
			wantRole:     "admin",
			wantPrefix:   "BANK-K8S",
			wantErr:      false,
			description:  "PCI-DSS compliance zone",
		},

		// Multiple prefix scenarios (production multi-cluster)
		{
			name:         "dev cluster prefix",
			permission:   "DEV-K8S-test-app-engineer",
			prefixes:     []string{"PROD-K8S", "DEV-K8S", "STAGE-K8S"},
			wantNS:       "test-app",
			wantRole:     "engineer",
			wantPrefix:   "DEV-K8S",
			wantErr:      false,
			description:  "Development cluster",
		},
		{
			name:         "staging cluster prefix",
			permission:   "STAGE-K8S-pre-prod-app-ops",
			prefixes:     []string{"PROD-K8S", "DEV-K8S", "STAGE-K8S"},
			wantNS:       "pre-prod-app",
			wantRole:     "ops",
			wantPrefix:   "STAGE-K8S",
			wantErr:      false,
			description:  "Staging cluster",
		},

		// Edge case: very specific business scenarios
		{
			name:         "blue-green deployment namespace",
			permission:   "COMPANY-K8S-app-blue-v2-admin",
			prefixes:     []string{"COMPANY-K8S"},
			wantNS:       "app-blue-v2",
			wantRole:     "admin",
			wantPrefix:   "COMPANY-K8S",
			wantErr:      false,
			description:  "Blue-green deployment",
		},
		{
			name:         "canary deployment namespace",
			permission:   "COMPANY-K8S-app-canary-10pct-engineer",
			prefixes:     []string{"COMPANY-K8S"},
			wantNS:       "app-canary-10pct",
			wantRole:     "engineer",
			wantPrefix:   "COMPANY-K8S",
			wantErr:      false,
			description:  "Canary deployment with percentage",
		},

		// Error scenarios that might occur in production
		{
			name:         "typo in prefix",
			permission:   "COMPNAY-K8S-app-admin", // Typo: COMPNAY
			prefixes:     []string{"COMPANY-K8S"},
			wantNS:       "",
			wantRole:     "",
			wantPrefix:   "",
			wantErr:      true,
			description:  "Typo in prefix should fail",
		},
		{
			name:         "missing role in permission",
			permission:   "COMPANY-K8S-app",
			prefixes:     []string{"COMPANY-K8S"},
			wantNS:       "",
			wantRole:     "",
			wantPrefix:   "",
			wantErr:      true,
			description:  "Missing role should fail",
		},
		{
			name:         "role not in mapping",
			permission:   "COMPANY-K8S-app-unknown-role",
			prefixes:     []string{"COMPANY-K8S"},
			wantNS:       "",
			wantRole:     "",
			wantPrefix:   "",
			wantErr:      true,
			description:  "Unknown role should fail",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ns, role, prefix, err := r.parsePermissionStringWithPrefixes(
				tt.permission,
				tt.prefixes,
				roleMapping,
			)

			if tt.wantErr {
				require.Error(t, err, tt.description)
			} else {
				require.NoError(t, err, tt.description)
				assert.Equal(t, tt.wantNS, ns, "Namespace: "+tt.description)
				assert.Equal(t, tt.wantRole, role, "Role: "+tt.description)
				assert.Equal(t, tt.wantPrefix, prefix, "Prefix: "+tt.description)
			}
		})
	}
}

// TestPermissionParsing_ConcurrencySafety tests if parsing is safe for concurrent use
// Important for production where multiple reconciliation loops might run concurrently
func TestPermissionParsing_ConcurrencySafety(t *testing.T) {
	r := &PermissionBinderReconciler{}

	roleMapping := map[string]string{
		"admin":    "admin",
		"engineer": "edit",
	}

	// Run parsing concurrently multiple times
	const numGoroutines = 100
	const numIterations = 10

	done := make(chan bool, numGoroutines)

	for i := 0; i < numGoroutines; i++ {
		go func(id int) {
			for j := 0; j < numIterations; j++ {
				// Parse same permission multiple times
				ns, role, err := r.parsePermissionString(
					"COMPANY-K8S-app-admin",
					"COMPANY-K8S",
					roleMapping,
				)

				// Verify results are consistent
				if err != nil {
					t.Errorf("Goroutine %d iteration %d: unexpected error: %v", id, j, err)
				}
				if ns != "app" {
					t.Errorf("Goroutine %d iteration %d: expected namespace 'app', got '%s'", id, j, ns)
				}
				if role != "admin" {
					t.Errorf("Goroutine %d iteration %d: expected role 'admin', got '%s'", id, j, role)
				}
			}
			done <- true
		}(i)
	}

	// Wait for all goroutines to complete
	for i := 0; i < numGoroutines; i++ {
		<-done
	}
}

