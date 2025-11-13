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
	"github.com/stretchr/testify/require"
	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// ============================================================================
// Helper Functions Tests
// ============================================================================

func TestGetNetworkPolicyName(t *testing.T) {
	tests := []struct {
		name        string
		namespace   string
		templateName string
		expected    string
	}{
		{
			name:        "Basic template name",
			namespace:   "my-namespace",
			templateName: "deny-all-ingress.yaml",
			expected:    "my-namespace-deny-all-ingress",
		},
		{
			name:        "Template name without extension",
			namespace:   "app",
			templateName: "deny-all-egress",
			expected:    "app-deny-all-egress",
		},
		{
			name:        "Complex namespace and template",
			namespace:   "application-service",
			templateName: "allow-prometheus-metrics.yaml",
			expected:    "application-service-allow-prometheus-metrics",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := getNetworkPolicyName(tt.namespace, tt.templateName)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestIsPolicyFromTemplate(t *testing.T) {
	tests := []struct {
		name        string
		policyName  string
		namespace   string
		templateName string
		expected    bool
	}{
		{
			name:        "Policy matches template",
			policyName:  "my-namespace-deny-all-ingress",
			namespace:   "my-namespace",
			templateName: "deny-all-ingress.yaml",
			expected:    true,
		},
		{
			name:        "Policy does not match template",
			policyName:  "my-namespace-other-policy",
			namespace:   "my-namespace",
			templateName: "deny-all-ingress.yaml",
			expected:    false,
		},
		{
			name:        "Policy with different namespace",
			policyName:  "other-namespace-deny-all-ingress",
			namespace:   "my-namespace",
			templateName: "deny-all-ingress.yaml",
			expected:    false,
		},
		{
			name:        "Policy name without namespace prefix",
			policyName:  "deny-all-ingress",
			namespace:   "my-namespace",
			templateName: "deny-all-ingress.yaml",
			expected:    false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := isPolicyFromTemplate(tt.policyName, tt.namespace, tt.templateName)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestIsNamespaceExcluded(t *testing.T) {
	tests := []struct {
		name        string
		namespace   string
		excludeList *permissionv1.NamespaceExcludeList
		expected    bool
	}{
		{
			name:      "Namespace in explicit list",
			namespace: "kube-system",
			excludeList: &permissionv1.NamespaceExcludeList{
				Explicit: []string{"kube-system", "kube-public"},
			},
			expected: true,
		},
		{
			name:      "Namespace matches pattern",
			namespace: "openshift-monitoring",
			excludeList: &permissionv1.NamespaceExcludeList{
				Patterns: []string{"^openshift-.*", "^kube-.*"},
			},
			expected: true,
		},
		{
			name:      "Namespace not excluded",
			namespace: "my-app",
			excludeList: &permissionv1.NamespaceExcludeList{
				Explicit: []string{"kube-system"},
				Patterns: []string{"^openshift-.*"},
			},
			expected: false,
		},
		{
			name:      "Nil exclude list",
			namespace: "my-app",
			excludeList: nil,
			expected: false,
		},
		{
			name:      "Empty exclude list",
			namespace: "my-app",
			excludeList: &permissionv1.NamespaceExcludeList{},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := IsNamespaceExcluded(tt.namespace, tt.excludeList)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestIsNamespaceExcludedFromBackup(t *testing.T) {
	tests := []struct {
		name        string
		namespace   string
		excludeList *permissionv1.NamespaceExcludeList
		expected    bool
	}{
		{
			name:      "Namespace excluded from backup",
			namespace: "my-app",
			excludeList: &permissionv1.NamespaceExcludeList{
				Explicit: []string{"my-app"},
			},
			expected: true,
		},
		{
			name:      "Namespace not excluded from backup",
			namespace: "other-app",
			excludeList: &permissionv1.NamespaceExcludeList{
				Explicit: []string{"my-app"},
			},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := isNamespaceExcludedFromBackup(tt.namespace, tt.excludeList)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestShouldBackupExistingPolicy(t *testing.T) {
	tests := []struct {
		name                  string
		namespace             string
		backupExisting        bool
		excludeBackupForNamespaces *permissionv1.NamespaceExcludeList
		expected              bool
	}{
		{
			name:          "Backup enabled, namespace not excluded",
			namespace:     "my-app",
			backupExisting: true,
			excludeBackupForNamespaces: nil,
			expected:      true,
		},
		{
			name:          "Backup disabled",
			namespace:     "my-app",
			backupExisting: false,
			excludeBackupForNamespaces: nil,
			expected:      false,
		},
		{
			name:          "Backup enabled but namespace excluded",
			namespace:     "my-app",
			backupExisting: true,
			excludeBackupForNamespaces: &permissionv1.NamespaceExcludeList{
				Explicit: []string{"my-app"},
			},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := shouldBackupExistingPolicy(tt.namespace, tt.backupExisting, tt.excludeBackupForNamespaces)
			assert.Equal(t, tt.expected, result)
		})
	}
}

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

// ============================================================================
// Rules Comparison Tests
// ============================================================================

func TestNormalizeNetworkPolicySpec(t *testing.T) {
	spec1 := networkingv1.NetworkPolicySpec{
		PodSelector: metav1.LabelSelector{
			MatchLabels: map[string]string{
				"app": "test",
			},
		},
		PolicyTypes: []networkingv1.PolicyType{
			networkingv1.PolicyTypeIngress,
			networkingv1.PolicyTypeEgress,
		},
		Ingress: []networkingv1.NetworkPolicyIngressRule{
			{
				From: []networkingv1.NetworkPolicyPeer{
					{
						PodSelector: &metav1.LabelSelector{
							MatchLabels: map[string]string{"app": "client"},
						},
					},
				},
			},
		},
	}

	normalized1 := normalizeNetworkPolicySpec(spec1)
	normalized2 := normalizeNetworkPolicySpec(spec1)

	// Same spec should produce same normalized output
	assert.Equal(t, normalized1, normalized2)
	assert.NotEmpty(t, normalized1)
}

func TestCalculateRulesHash(t *testing.T) {
	spec1 := networkingv1.NetworkPolicySpec{
		PodSelector: metav1.LabelSelector{
			MatchLabels: map[string]string{"app": "test"},
		},
		PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress},
	}

	spec2 := networkingv1.NetworkPolicySpec{
		PodSelector: metav1.LabelSelector{
			MatchLabels: map[string]string{"app": "test"},
		},
		PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress},
	}

	hash1 := calculateRulesHash(spec1)
	hash2 := calculateRulesHash(spec2)

	// Same rules should produce same hash
	assert.Equal(t, hash1, hash2)
	assert.NotEmpty(t, hash1)
	assert.Len(t, hash1, 64) // SHA256 hex string length
}

func TestCompareNetworkPolicyRules(t *testing.T) {
	tests := []struct {
		name     string
		spec1    networkingv1.NetworkPolicySpec
		spec2    networkingv1.NetworkPolicySpec
		expected bool
	}{
		{
			name: "Identical specs",
			spec1: networkingv1.NetworkPolicySpec{
				PodSelector: metav1.LabelSelector{
					MatchLabels: map[string]string{"app": "test"},
				},
				PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress},
			},
			spec2: networkingv1.NetworkPolicySpec{
				PodSelector: metav1.LabelSelector{
					MatchLabels: map[string]string{"app": "test"},
				},
				PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress},
			},
			expected: true,
		},
		{
			name: "Different pod selectors",
			spec1: networkingv1.NetworkPolicySpec{
				PodSelector: metav1.LabelSelector{
					MatchLabels: map[string]string{"app": "test"},
				},
				PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress},
			},
			spec2: networkingv1.NetworkPolicySpec{
				PodSelector: metav1.LabelSelector{
					MatchLabels: map[string]string{"app": "other"},
				},
				PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress},
			},
			expected: false,
		},
		{
			name: "Different policy types",
			spec1: networkingv1.NetworkPolicySpec{
				PodSelector: metav1.LabelSelector{
					MatchLabels: map[string]string{"app": "test"},
				},
				PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress},
			},
			spec2: networkingv1.NetworkPolicySpec{
				PodSelector: metav1.LabelSelector{
					MatchLabels: map[string]string{"app": "test"},
				},
				PolicyTypes: []networkingv1.PolicyType{
					networkingv1.PolicyTypeIngress,
					networkingv1.PolicyTypeEgress,
				},
			},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := compareNetworkPolicyRules(tt.spec1, tt.spec2)
			assert.Equal(t, tt.expected, result)
		})
	}
}

// ============================================================================
// Status Tracking Tests
// ============================================================================

func TestGetNetworkPolicyStatus(t *testing.T) {
	statusEntry := permissionv1.NetworkPolicyStatus{
		Namespace: "my-namespace",
		State:     "pr-created",
	}

	permissionBinder := &permissionv1.PermissionBinder{
		Status: permissionv1.PermissionBinderStatus{
			NetworkPolicies: []permissionv1.NetworkPolicyStatus{statusEntry},
		},
	}

	// Test existing status
	result := getNetworkPolicyStatus(permissionBinder, "my-namespace")
	require.NotNil(t, result)
	assert.Equal(t, "my-namespace", result.Namespace)
	assert.Equal(t, "pr-created", result.State)

	// Test non-existing status
	result = getNetworkPolicyStatus(permissionBinder, "other-namespace")
	assert.Nil(t, result)
}

func TestHasNetworkPolicyStatus(t *testing.T) {
	permissionBinder := &permissionv1.PermissionBinder{
		Status: permissionv1.PermissionBinderStatus{
			NetworkPolicies: []permissionv1.NetworkPolicyStatus{
				{Namespace: "my-namespace", State: "pr-created"},
			},
		},
	}

	assert.True(t, hasNetworkPolicyStatus(permissionBinder, "my-namespace"))
	assert.False(t, hasNetworkPolicyStatus(permissionBinder, "other-namespace"))
}

// ============================================================================
// Batch Processing Tests
// ============================================================================

func TestChunkNamespaces(t *testing.T) {
	tests := []struct {
		name      string
		namespaces []string
		batchSize int
		expectedBatches int
	}{
		{
			name:      "Single batch",
			namespaces: []string{"ns1", "ns2", "ns3"},
			batchSize: 5,
			expectedBatches: 1,
		},
		{
			name:      "Multiple batches",
			namespaces: []string{"ns1", "ns2", "ns3", "ns4", "ns5", "ns6"},
			batchSize: 2,
			expectedBatches: 3,
		},
		{
			name:      "Empty list",
			namespaces: []string{},
			batchSize: 5,
			expectedBatches: 0,
		},
		{
			name:      "Exact batch size",
			namespaces: []string{"ns1", "ns2", "ns3", "ns4", "ns5"},
			batchSize: 5,
			expectedBatches: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			batches := chunkNamespaces(tt.namespaces, tt.batchSize)
			assert.Equal(t, tt.expectedBatches, len(batches))

			// Verify all namespaces are included
			totalNamespaces := 0
			for _, batch := range batches {
				totalNamespaces += len(batch)
			}
			assert.Equal(t, len(tt.namespaces), totalNamespaces)
		})
	}
}

// ============================================================================
// Integration Tests with Ginkgo
// ============================================================================
// NOTE: Integration tests require k8sClient and PermissionBinderReconciler
// which are defined in the parent 'controller' package. These tests should
// be moved to permissionbinder_controller_test.go or a separate integration
// test file in the controller package.
//
// TODO: Move integration tests to controller package or create proper test setup
// for networkpolicy package integration tests.

