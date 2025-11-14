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
// Naming & Policy Identification Tests
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

