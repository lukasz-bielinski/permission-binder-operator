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

