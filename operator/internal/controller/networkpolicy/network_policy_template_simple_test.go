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

// TestCleanJSONForGitOps_RemoveManagedFields tests removal of Kubernetes internal fields
func TestCleanJSONForGitOps_RemoveManagedFields(t *testing.T) {
	tests := []struct {
		name  string
		input map[string]interface{}
		want  map[string]interface{}
	}{
		{
			name: "removes managed fields from metadata",
			input: map[string]interface{}{
				"apiVersion": "networking.k8s.io/v1",
				"kind":       "NetworkPolicy",
				"metadata": map[string]interface{}{
					"name":              "test-policy",
					"namespace":         "test-ns",
					"managedFields":     []interface{}{map[string]interface{}{"manager": "kubectl"}},
					"creationTimestamp": "2025-01-01T00:00:00Z",
					"generation":        int64(1),
					"uid":               "123e4567-e89b-12d3-a456-426614174000",
					"resourceVersion":   "12345",
					"selfLink":          "/api/v1/namespaces/test-ns/networkpolicies/test-policy",
				},
			},
			want: map[string]interface{}{
				"apiVersion": "networking.k8s.io/v1",
				"kind":       "NetworkPolicy",
				"metadata": map[string]interface{}{
					"name":      "test-policy",
					"namespace": "test-ns",
				},
			},
		},
		{
			name: "preserves important metadata fields",
			input: map[string]interface{}{
				"apiVersion": "networking.k8s.io/v1",
				"kind":       "NetworkPolicy",
				"metadata": map[string]interface{}{
					"name":              "test-policy",
					"namespace":         "test-ns",
					"labels":            map[string]interface{}{"app": "test"},
					"annotations":       map[string]interface{}{"custom": "value"},
					"managedFields":     []interface{}{},
					"creationTimestamp": "2025-01-01T00:00:00Z",
				},
			},
			want: map[string]interface{}{
				"apiVersion": "networking.k8s.io/v1",
				"kind":       "NetworkPolicy",
				"metadata": map[string]interface{}{
					"name":        "test-policy",
					"namespace":   "test-ns",
					"labels":      map[string]interface{}{"app": "test"},
					"annotations": map[string]interface{}{"custom": "value"},
				},
			},
		},
		{
			name: "removes empty labels and annotations",
			input: map[string]interface{}{
				"apiVersion": "networking.k8s.io/v1",
				"kind":       "NetworkPolicy",
				"metadata": map[string]interface{}{
					"name":        "test-policy",
					"namespace":   "test-ns",
					"labels":      map[string]interface{}{},
					"annotations": map[string]interface{}{},
				},
			},
			want: map[string]interface{}{
				"apiVersion": "networking.k8s.io/v1",
				"kind":       "NetworkPolicy",
				"metadata": map[string]interface{}{
					"name":      "test-policy",
					"namespace": "test-ns",
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cleanJSONForGitOps(tt.input)
			assert.Equal(t, tt.want, tt.input)
		})
	}
}

// TestCleanJSONForGitOps_RemoveStatus tests status field removal
func TestCleanJSONForGitOps_RemoveStatus(t *testing.T) {
	input := map[string]interface{}{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
		"metadata": map[string]interface{}{
			"name":      "test-policy",
			"namespace": "test-ns",
		},
		"spec": map[string]interface{}{
			"podSelector": map[string]interface{}{},
		},
		"status": map[string]interface{}{
			"conditions": []interface{}{},
		},
	}

	cleanJSONForGitOps(input)

	assert.NotContains(t, input, "status", "status field should be removed")
	assert.Contains(t, input, "spec", "spec field should be preserved")
}

// TestCleanJSONForGitOps_EnsureAPIVersionAndKind tests that apiVersion and kind are always present
func TestCleanJSONForGitOps_EnsureAPIVersionAndKind(t *testing.T) {
	tests := []struct {
		name  string
		input map[string]interface{}
	}{
		{
			name: "adds missing apiVersion",
			input: map[string]interface{}{
				"kind": "NetworkPolicy",
				"metadata": map[string]interface{}{
					"name": "test-policy",
				},
			},
		},
		{
			name: "adds missing kind",
			input: map[string]interface{}{
				"apiVersion": "networking.k8s.io/v1",
				"metadata": map[string]interface{}{
					"name": "test-policy",
				},
			},
		},
		{
			name: "adds both apiVersion and kind",
			input: map[string]interface{}{
				"metadata": map[string]interface{}{
					"name": "test-policy",
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cleanJSONForGitOps(tt.input)

			assert.Equal(t, "networking.k8s.io/v1", tt.input["apiVersion"], "apiVersion should be set")
			assert.Equal(t, "NetworkPolicy", tt.input["kind"], "kind should be set")
		})
	}
}

// TestCleanJSONForGitOps_PreserveExistingAPIVersionAndKind tests that existing apiVersion and kind are not overwritten
func TestCleanJSONForGitOps_PreserveExistingAPIVersionAndKind(t *testing.T) {
	input := map[string]interface{}{
		"apiVersion": "networking.k8s.io/v1beta1",
		"kind":       "NetworkPolicy",
		"metadata": map[string]interface{}{
			"name": "test-policy",
		},
	}

	cleanJSONForGitOps(input)

	assert.Equal(t, "networking.k8s.io/v1beta1", input["apiVersion"], "existing apiVersion should be preserved")
	assert.Equal(t, "NetworkPolicy", input["kind"], "existing kind should be preserved")
}

// TestCleanJSONForGitOps_InternalAnnotations tests removal of internal Kubernetes annotations
func TestCleanJSONForGitOps_InternalAnnotations(t *testing.T) {
	input := map[string]interface{}{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
		"metadata": map[string]interface{}{
			"name":      "test-policy",
			"namespace": "test-ns",
			"annotations": map[string]interface{}{
				"kubectl.kubernetes.io/last-applied-configuration": "...",
				"deployment.kubernetes.io/revision":                "1",
				"kubernetes.io/change-cause":                        "manual update",
				"custom.example.com/annotation":                     "keep-this",
				"permission-binder.io/template":                     "keep-this-too",
			},
		},
	}

	cleanJSONForGitOps(input)

	metadata := input["metadata"].(map[string]interface{})
	annotations := metadata["annotations"].(map[string]interface{})

	// Internal annotations should be removed
	assert.NotContains(t, annotations, "kubectl.kubernetes.io/last-applied-configuration")
	assert.NotContains(t, annotations, "deployment.kubernetes.io/revision")
	assert.NotContains(t, annotations, "kubernetes.io/change-cause")

	// Custom annotations should be preserved
	assert.Contains(t, annotations, "custom.example.com/annotation")
	assert.Contains(t, annotations, "permission-binder.io/template")
}

// TestCleanJSONForGitOps_EmptyMetadata tests handling of empty metadata
func TestCleanJSONForGitOps_EmptyMetadata(t *testing.T) {
	input := map[string]interface{}{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
	}

	// Should not panic
	assert.NotPanics(t, func() {
		cleanJSONForGitOps(input)
	})

	// Should still have apiVersion and kind
	assert.Equal(t, "networking.k8s.io/v1", input["apiVersion"])
	assert.Equal(t, "NetworkPolicy", input["kind"])
}

// TestIsInternalKubernetesAnnotation tests internal annotation detection
func TestIsInternalKubernetesAnnotation(t *testing.T) {
	tests := []struct {
		name       string
		annotation string
		want       bool
	}{
		{
			name:       "kubectl annotation",
			annotation: "kubectl.kubernetes.io/last-applied-configuration",
			want:       true,
		},
		{
			name:       "deployment annotation",
			annotation: "deployment.kubernetes.io/revision",
			want:       true,
		},
		{
			name:       "pod-template-hash",
			annotation: "pod-template-hash",
			want:       true,
		},
		{
			name:       "generic kubernetes.io annotation",
			annotation: "kubernetes.io/change-cause",
			want:       true,
		},
		{
			name:       "custom annotation with kubernetes in name",
			annotation: "custom.kubernetes.example.com/annotation",
			want:       false,
		},
		{
			name:       "permission-binder annotation",
			annotation: "permission-binder.io/template",
			want:       false,
		},
		{
			name:       "custom domain annotation",
			annotation: "custom.example.com/annotation",
			want:       false,
		},
		{
			name:       "empty annotation",
			annotation: "",
			want:       false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isInternalKubernetesAnnotation(tt.annotation)
			assert.Equal(t, tt.want, got)
		})
	}
}

// TestCleanJSONForGitOps_ComplexMetadata tests cleaning of complex metadata structures
func TestCleanJSONForGitOps_ComplexMetadata(t *testing.T) {
	input := map[string]interface{}{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
		"metadata": map[string]interface{}{
			"name":      "complex-policy",
			"namespace": "production",
			"labels": map[string]interface{}{
				"app":     "nginx",
				"version": "1.0.0",
				"tier":    "frontend",
			},
			"annotations": map[string]interface{}{
				"kubectl.kubernetes.io/last-applied-configuration": `{"apiVersion":"v1","kind":"NetworkPolicy"}`,
				"permission-binder.io/template":                     "ingress-template.yaml",
				"permission-binder.io/template-path":                "templates/network-policies/ingress-template.yaml",
				"custom.example.com/owner":                          "team-a",
			},
			"managedFields": []interface{}{
				map[string]interface{}{
					"manager":   "kubectl",
					"operation": "Update",
				},
			},
			"creationTimestamp": "2025-01-01T12:00:00Z",
			"generation":        int64(5),
			"uid":               "123e4567-e89b-12d3-a456-426614174000",
			"resourceVersion":   "98765",
		},
		"spec": map[string]interface{}{
			"podSelector": map[string]interface{}{
				"matchLabels": map[string]interface{}{
					"app": "nginx",
				},
			},
		},
	}

	expected := map[string]interface{}{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
		"metadata": map[string]interface{}{
			"name":      "complex-policy",
			"namespace": "production",
			"labels": map[string]interface{}{
				"app":     "nginx",
				"version": "1.0.0",
				"tier":    "frontend",
			},
			"annotations": map[string]interface{}{
				"permission-binder.io/template":      "ingress-template.yaml",
				"permission-binder.io/template-path": "templates/network-policies/ingress-template.yaml",
				"custom.example.com/owner":           "team-a",
			},
		},
		"spec": map[string]interface{}{
			"podSelector": map[string]interface{}{
				"matchLabels": map[string]interface{}{
					"app": "nginx",
				},
			},
		},
	}

	cleanJSONForGitOps(input)

	assert.Equal(t, expected, input)
}

// TestCleanJSONForGitOps_NilMetadataFields tests handling of nil metadata fields
func TestCleanJSONForGitOps_NilMetadataFields(t *testing.T) {
	input := map[string]interface{}{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
		"metadata": map[string]interface{}{
			"name":        "test-policy",
			"namespace":   "test-ns",
			"labels":      nil,
			"annotations": nil,
		},
	}

	// Should not panic
	assert.NotPanics(t, func() {
		cleanJSONForGitOps(input)
	})
}

// TestCleanJSONForGitOps_OnlyInternalAnnotations tests removal when only internal annotations exist
func TestCleanJSONForGitOps_OnlyInternalAnnotations(t *testing.T) {
	input := map[string]interface{}{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
		"metadata": map[string]interface{}{
			"name":      "test-policy",
			"namespace": "test-ns",
			"annotations": map[string]interface{}{
				"kubectl.kubernetes.io/last-applied-configuration": "...",
				"deployment.kubernetes.io/revision":                "1",
			},
		},
	}

	cleanJSONForGitOps(input)

	metadata := input["metadata"].(map[string]interface{})
	// Annotations should be completely removed when all were internal
	assert.NotContains(t, metadata, "annotations", "annotations should be removed when all were internal")
}

// TestCleanJSONForGitOps_PreserveSpec tests that spec is never modified
func TestCleanJSONForGitOps_PreserveSpec(t *testing.T) {
	originalSpec := map[string]interface{}{
		"podSelector": map[string]interface{}{
			"matchLabels": map[string]interface{}{
				"app": "test",
			},
		},
		"ingress": []interface{}{
			map[string]interface{}{
				"from": []interface{}{
					map[string]interface{}{
						"podSelector": map[string]interface{}{
							"matchLabels": map[string]interface{}{
								"role": "frontend",
							},
						},
					},
				},
			},
		},
	}

	input := map[string]interface{}{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
		"metadata": map[string]interface{}{
			"name":              "test-policy",
			"managedFields":     []interface{}{},
			"creationTimestamp": "2025-01-01T00:00:00Z",
		},
		"spec": originalSpec,
	}

	cleanJSONForGitOps(input)

	// Spec should be unchanged
	assert.Equal(t, originalSpec, input["spec"], "spec should never be modified")
}

// Benchmark tests for performance monitoring
func BenchmarkCleanJSONForGitOps_Simple(b *testing.B) {
	input := map[string]interface{}{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
		"metadata": map[string]interface{}{
			"name":              "test-policy",
			"namespace":         "test-ns",
			"managedFields":     []interface{}{},
			"creationTimestamp": "2025-01-01T00:00:00Z",
		},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		// Create a copy for each iteration
		testInput := make(map[string]interface{})
		for k, v := range input {
			testInput[k] = v
		}
		cleanJSONForGitOps(testInput)
	}
}

func BenchmarkCleanJSONForGitOps_Complex(b *testing.B) {
	input := map[string]interface{}{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
		"metadata": map[string]interface{}{
			"name":      "complex-policy",
			"namespace": "production",
			"labels": map[string]interface{}{
				"app": "nginx", "version": "1.0.0", "tier": "frontend",
			},
			"annotations": map[string]interface{}{
				"kubectl.kubernetes.io/last-applied-configuration": "...",
				"permission-binder.io/template":                     "template.yaml",
				"custom.example.com/owner":                          "team-a",
			},
			"managedFields":     []interface{}{map[string]interface{}{"manager": "kubectl"}},
			"creationTimestamp": "2025-01-01T12:00:00Z",
			"generation":        int64(5),
		},
		"spec": map[string]interface{}{
			"podSelector": map[string]interface{}{
				"matchLabels": map[string]interface{}{"app": "nginx"},
			},
		},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		// Create a deep copy for each iteration
		testInput := make(map[string]interface{})
		for k, v := range input {
			testInput[k] = v
		}
		cleanJSONForGitOps(testInput)
	}
}

func BenchmarkIsInternalKubernetesAnnotation(b *testing.B) {
	annotations := []string{
		"kubectl.kubernetes.io/last-applied-configuration",
		"deployment.kubernetes.io/revision",
		"permission-binder.io/template",
		"custom.example.com/annotation",
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for _, ann := range annotations {
			_ = isInternalKubernetesAnnotation(ann)
		}
	}
}

