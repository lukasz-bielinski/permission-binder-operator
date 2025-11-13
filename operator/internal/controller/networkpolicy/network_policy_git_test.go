/*
Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package networkpolicy

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// ============================================================================
// File Path & Git Operations Tests
// ============================================================================

func TestGetNetworkPolicyFilePath(t *testing.T) {
	tests := []struct {
		name        string
		clusterName string
		namespace   string
		fileName    string
		expected    string
	}{
		{
			name:        "Basic path",
			clusterName: "DEV-cluster",
			namespace:   "my-app",
			fileName:    "my-app-deny-all-ingress.yaml",
			expected:    "networkpolicies/DEV-cluster/my-app/my-app-deny-all-ingress.yaml",
		},
		{
			name:        "Complex path",
			clusterName: "PROD-cluster",
			namespace:   "application-service",
			fileName:    "policy.yaml",
			expected:    "networkpolicies/PROD-cluster/application-service/policy.yaml",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := getNetworkPolicyFilePath(tt.clusterName, tt.namespace, tt.fileName)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestDetectGitProvider(t *testing.T) {
	tests := []struct {
		name        string
		url         string
		explicitProvider string
		expected    string
		expectError bool
	}{
		{
			name:        "GitHub URL",
			url:         "https://github.com/owner/repo.git",
			explicitProvider: "",
			expected:    "github",
			expectError: false,
		},
		{
			name:        "Bitbucket URL",
			url:         "https://bitbucket.org/workspace/repo.git",
			explicitProvider: "",
			expected:    "bitbucket",
			expectError: false,
		},
		{
			name:        "GitLab URL",
			url:         "https://gitlab.com/group/project.git",
			explicitProvider: "",
			expected:    "gitlab",
			expectError: false,
		},
		{
			name:        "Explicit provider overrides URL",
			url:         "https://github.com/owner/repo.git",
			explicitProvider: "bitbucket",
			expected:    "bitbucket",
			expectError: false,
		},
		{
			name:        "Self-hosted with explicit provider",
			url:         "https://git.cembraintra.ch/repo.git",
			explicitProvider: "bitbucket",
			expected:    "bitbucket",
			expectError: false,
		},
		{
			name:        "Unknown URL, no explicit provider",
			url:         "https://unknown-git.com/repo.git",
			explicitProvider: "",
			expected:    "",
			expectError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := detectGitProvider(tt.url, tt.explicitProvider)
			if tt.expectError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
				assert.Equal(t, tt.expected, result)
			}
		})
	}
}

func TestGenerateBranchName(t *testing.T) {
	tests := []struct {
		name        string
		clusterName string
		namespace   string
		expected    string
	}{
		{
			name:        "Basic branch name",
			clusterName: "DEV-cluster",
			namespace:   "my-app",
			expected:    "networkpolicy/DEV-cluster/my-app",
		},
		{
			name:        "Complex names",
			clusterName: "PROD-cluster",
			namespace:   "application-service",
			expected:    "networkpolicy/PROD-cluster/application-service",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := generateBranchName(tt.clusterName, tt.namespace)
			assert.Equal(t, tt.expected, result, "Branch name should match expected format")
		})
	}
}

