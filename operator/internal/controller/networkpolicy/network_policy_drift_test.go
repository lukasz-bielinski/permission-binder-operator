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
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
)

// NOTE: TestCalculateRulesHash, TestCompareNetworkPolicyRules, and TestNormalizeNetworkPolicySpec
// are already in network_policy_helper_test.go. This file focuses on normalization functions.

// TestNormalizeSelector tests label selector normalization
func TestNormalizeSelector(t *testing.T) {
	tests := []struct {
		name     string
		selector metav1.LabelSelector
		want     map[string]interface{}
	}{
		{
			name: "empty selector",
			selector: metav1.LabelSelector{
				MatchLabels:      nil,
				MatchExpressions: nil,
			},
			want: map[string]interface{}{},
		},
		{
			name: "only matchLabels",
			selector: metav1.LabelSelector{
				MatchLabels: map[string]string{
					"app":  "nginx",
					"tier": "frontend",
				},
			},
			want: map[string]interface{}{
				"matchLabels": map[string]string{
					"app":  "nginx",
					"tier": "frontend",
				},
			},
		},
		{
			name: "with matchExpressions",
			selector: metav1.LabelSelector{
				MatchExpressions: []metav1.LabelSelectorRequirement{
					{
						Key:      "environment",
						Operator: metav1.LabelSelectorOpIn,
						Values:   []string{"prod", "staging"},
					},
				},
			},
			want: map[string]interface{}{
				"matchExpressions": []interface{}{
					map[string]interface{}{
						"key":      "environment",
						"operator": metav1.LabelSelectorOpIn,
						"values":   []string{"prod", "staging"},
					},
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeSelector(tt.selector)
			// Compare JSON representations for deep equality
			gotJSON, _ := json.Marshal(got)
			wantJSON, _ := json.Marshal(tt.want)
			assert.JSONEq(t, string(wantJSON), string(gotJSON))
		})
	}
}

// TestNormalizePorts tests port normalization
func TestNormalizePorts(t *testing.T) {
	protocol := corev1.ProtocolTCP
	port80 := intstr.FromInt(80)
	port443 := intstr.FromInt(443)

	tests := []struct {
		name  string
		ports []networkingv1.NetworkPolicyPort
	}{
		{
			name:  "nil ports",
			ports: nil,
		},
		{
			name:  "empty ports",
			ports: []networkingv1.NetworkPolicyPort{},
		},
		{
			name: "single port",
			ports: []networkingv1.NetworkPolicyPort{
				{
					Protocol: &protocol,
					Port:     &port80,
				},
			},
		},
		{
			name: "multiple ports",
			ports: []networkingv1.NetworkPolicyPort{
				{
					Protocol: &protocol,
					Port:     &port443,
				},
				{
					Protocol: &protocol,
					Port:     &port80,
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizePorts(tt.ports)
			// Should not panic
			assert.NotNil(t, got)
			// Should be sorted
			if len(got) > 1 {
				for i := 0; i < len(got)-1; i++ {
					iJSON, _ := json.Marshal(got[i])
					jJSON, _ := json.Marshal(got[i+1])
					assert.True(t, string(iJSON) <= string(jJSON), "ports should be sorted")
				}
			}
		})
	}
}

// TestNormalizeNetworkPolicyPeers tests peer normalization
func TestNormalizeNetworkPolicyPeers(t *testing.T) {
	tests := []struct {
		name  string
		peers []networkingv1.NetworkPolicyPeer
	}{
		{
			name:  "nil peers",
			peers: nil,
		},
		{
			name:  "empty peers",
			peers: []networkingv1.NetworkPolicyPeer{},
		},
		{
			name: "single peer with pod selector",
			peers: []networkingv1.NetworkPolicyPeer{
				{
					PodSelector: &metav1.LabelSelector{
						MatchLabels: map[string]string{"app": "web"},
					},
				},
			},
		},
		{
			name: "multiple peers",
			peers: []networkingv1.NetworkPolicyPeer{
				{
					PodSelector: &metav1.LabelSelector{
						MatchLabels: map[string]string{"app": "db"},
					},
				},
				{
					PodSelector: &metav1.LabelSelector{
						MatchLabels: map[string]string{"app": "web"},
					},
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeNetworkPolicyPeers(tt.peers)
			assert.NotNil(t, got)
			// Should be sorted
			if len(got) > 1 {
				for i := 0; i < len(got)-1; i++ {
					iJSON, _ := json.Marshal(got[i])
					jJSON, _ := json.Marshal(got[i+1])
					assert.True(t, string(iJSON) <= string(jJSON), "peers should be sorted")
				}
			}
		})
	}
}

// TestNormalizeIngressRules tests ingress rule normalization
func TestNormalizeIngressRules(t *testing.T) {
	protocol := corev1.ProtocolTCP
	port80 := intstr.FromInt(80)

	tests := []struct {
		name  string
		rules []networkingv1.NetworkPolicyIngressRule
	}{
		{
			name:  "nil rules",
			rules: nil,
		},
		{
			name:  "empty rules",
			rules: []networkingv1.NetworkPolicyIngressRule{},
		},
		{
			name: "single rule",
			rules: []networkingv1.NetworkPolicyIngressRule{
				{
					Ports: []networkingv1.NetworkPolicyPort{
						{
							Protocol: &protocol,
							Port:     &port80,
						},
					},
					From: []networkingv1.NetworkPolicyPeer{
						{
							PodSelector: &metav1.LabelSelector{
								MatchLabels: map[string]string{"app": "web"},
							},
						},
					},
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeIngressRules(tt.rules)
			assert.NotNil(t, got)
			// Should be sorted
			if len(got) > 1 {
				for i := 0; i < len(got)-1; i++ {
					iJSON, _ := json.Marshal(got[i])
					jJSON, _ := json.Marshal(got[i+1])
					assert.True(t, string(iJSON) <= string(jJSON), "ingress rules should be sorted")
				}
			}
		})
	}
}

// TestNormalizeEgressRules tests egress rule normalization
func TestNormalizeEgressRules(t *testing.T) {
	protocol := corev1.ProtocolTCP
	port443 := intstr.FromInt(443)

	tests := []struct {
		name  string
		rules []networkingv1.NetworkPolicyEgressRule
	}{
		{
			name:  "nil rules",
			rules: nil,
		},
		{
			name:  "empty rules",
			rules: []networkingv1.NetworkPolicyEgressRule{},
		},
		{
			name: "single rule",
			rules: []networkingv1.NetworkPolicyEgressRule{
				{
					Ports: []networkingv1.NetworkPolicyPort{
						{
							Protocol: &protocol,
							Port:     &port443,
						},
					},
					To: []networkingv1.NetworkPolicyPeer{
						{
							IPBlock: &networkingv1.IPBlock{
								CIDR: "0.0.0.0/0",
							},
						},
					},
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeEgressRules(tt.rules)
			assert.NotNil(t, got)
			// Should be sorted
			if len(got) > 1 {
				for i := 0; i < len(got)-1; i++ {
					iJSON, _ := json.Marshal(got[i])
					jJSON, _ := json.Marshal(got[i+1])
					assert.True(t, string(iJSON) <= string(jJSON), "egress rules should be sorted")
				}
			}
		})
	}
}

// Benchmark tests for performance monitoring
func BenchmarkNormalizePorts(b *testing.B) {
	protocol := corev1.ProtocolTCP
	port80 := intstr.FromInt(80)

	ports := []networkingv1.NetworkPolicyPort{
		{Protocol: &protocol, Port: &port80},
		{Protocol: &protocol, Port: &port80},
		{Protocol: &protocol, Port: &port80},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = normalizePorts(ports)
	}
}

func BenchmarkNormalizeIngressRules(b *testing.B) {
	protocol := corev1.ProtocolTCP
	port80 := intstr.FromInt(80)

	rules := []networkingv1.NetworkPolicyIngressRule{
		{
			Ports: []networkingv1.NetworkPolicyPort{
				{Protocol: &protocol, Port: &port80},
			},
		},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = normalizeIngressRules(rules)
	}
}
