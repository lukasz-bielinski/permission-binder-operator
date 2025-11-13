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
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	kustypes "sigs.k8s.io/kustomize/api/types"
	"sigs.k8s.io/yaml"
)

// TestEnsureKustomizationExistsSimple_NewFile tests creating a new kustomization.yaml
func TestEnsureKustomizationExistsSimple_NewFile(t *testing.T) {
	// Create temp directory
	tmpDir, err := os.MkdirTemp("", "test-kustomization-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()
	kustomizationPath := "kustomization.yaml"

	// Ensure kustomization is created
	err = ensureKustomizationExistsSimple(nil, ctx, tmpDir, kustomizationPath)
	require.NoError(t, err)

	// Verify file exists
	fullPath := filepath.Join(tmpDir, kustomizationPath)
	assert.FileExists(t, fullPath)

	// Verify content
	content, err := os.ReadFile(fullPath)
	require.NoError(t, err)

	var kustomization kustypes.Kustomization
	err = yaml.Unmarshal(content, &kustomization)
	require.NoError(t, err)

	assert.Equal(t, "kustomize.config.k8s.io/v1beta1", kustomization.APIVersion)
	assert.Equal(t, "Kustomization", kustomization.Kind)
	assert.Empty(t, kustomization.Resources)
}

// TestEnsureKustomizationExistsSimple_ExistingFile tests that existing file is not overwritten
func TestEnsureKustomizationExistsSimple_ExistingFile(t *testing.T) {
	// Create temp directory
	tmpDir, err := os.MkdirTemp("", "test-kustomization-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()
	kustomizationPath := "kustomization.yaml"

	// Create existing kustomization with custom content
	existingKustomization := kustypes.Kustomization{
		TypeMeta: kustypes.TypeMeta{
			APIVersion: "kustomize.config.k8s.io/v1beta1",
			Kind:       "Kustomization",
		},
		Resources: []string{"existing-resource.yaml"},
	}
	existingContent, err := yaml.Marshal(existingKustomization)
	require.NoError(t, err)

	fullPath := filepath.Join(tmpDir, kustomizationPath)
	err = os.WriteFile(fullPath, existingContent, 0644)
	require.NoError(t, err)

	// Ensure kustomization exists (should not overwrite)
	err = ensureKustomizationExistsSimple(nil, ctx, tmpDir, kustomizationPath)
	require.NoError(t, err)

	// Verify original content is preserved
	content, err := os.ReadFile(fullPath)
	require.NoError(t, err)

	var kustomization kustypes.Kustomization
	err = yaml.Unmarshal(content, &kustomization)
	require.NoError(t, err)

	assert.Equal(t, []string{"existing-resource.yaml"}, kustomization.Resources)
}

// TestEnsureKustomizationExistsSimple_NestedDirectory tests creating in nested directory
func TestEnsureKustomizationExistsSimple_NestedDirectory(t *testing.T) {
	// Create temp directory
	tmpDir, err := os.MkdirTemp("", "test-kustomization-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()
	
	// Create nested directory
	nestedDir := filepath.Join("cluster", "namespace")
	err = os.MkdirAll(filepath.Join(tmpDir, nestedDir), 0755)
	require.NoError(t, err)

	kustomizationPath := filepath.Join(nestedDir, "kustomization.yaml")

	// Ensure kustomization is created
	err = ensureKustomizationExistsSimple(nil, ctx, tmpDir, kustomizationPath)
	require.NoError(t, err)

	// Verify file exists
	fullPath := filepath.Join(tmpDir, kustomizationPath)
	assert.FileExists(t, fullPath)
}

// TestUpdateKustomizationResourcesSimple_AddResource tests adding a resource
func TestUpdateKustomizationResourcesSimple_AddResource(t *testing.T) {
	// Create temp directory
	tmpDir, err := os.MkdirTemp("", "test-kustomization-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()
	kustomizationPath := "kustomization.yaml"

	// Create initial kustomization
	err = ensureKustomizationExistsSimple(nil, ctx, tmpDir, kustomizationPath)
	require.NoError(t, err)

	// Add resource
	resourcePath := "policy1.yaml"
	err = updateKustomizationResourcesSimple(nil, ctx, tmpDir, kustomizationPath, resourcePath, true)
	require.NoError(t, err)

	// Verify resource was added
	fullPath := filepath.Join(tmpDir, kustomizationPath)
	content, err := os.ReadFile(fullPath)
	require.NoError(t, err)

	var kustomization kustypes.Kustomization
	err = yaml.Unmarshal(content, &kustomization)
	require.NoError(t, err)

	assert.Contains(t, kustomization.Resources, resourcePath)
}

// TestUpdateKustomizationResourcesSimple_RemoveResource tests removing a resource
func TestUpdateKustomizationResourcesSimple_RemoveResource(t *testing.T) {
	// Create temp directory
	tmpDir, err := os.MkdirTemp("", "test-kustomization-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()
	kustomizationPath := "kustomization.yaml"

	// Create initial kustomization with resources
	initialKustomization := kustypes.Kustomization{
		TypeMeta: kustypes.TypeMeta{
			APIVersion: "kustomize.config.k8s.io/v1beta1",
			Kind:       "Kustomization",
		},
		Resources: []string{"policy1.yaml", "policy2.yaml", "policy3.yaml"},
	}
	initialContent, err := yaml.Marshal(initialKustomization)
	require.NoError(t, err)

	fullPath := filepath.Join(tmpDir, kustomizationPath)
	err = os.WriteFile(fullPath, initialContent, 0644)
	require.NoError(t, err)

	// Remove resource
	resourcePath := "policy2.yaml"
	err = updateKustomizationResourcesSimple(nil, ctx, tmpDir, kustomizationPath, resourcePath, false)
	require.NoError(t, err)

	// Verify resource was removed
	content, err := os.ReadFile(fullPath)
	require.NoError(t, err)

	var kustomization kustypes.Kustomization
	err = yaml.Unmarshal(content, &kustomization)
	require.NoError(t, err)

	assert.NotContains(t, kustomization.Resources, resourcePath)
	assert.Contains(t, kustomization.Resources, "policy1.yaml")
	assert.Contains(t, kustomization.Resources, "policy3.yaml")
}

// TestUpdateKustomizationResourcesSimple_AddDuplicate tests that duplicates are removed
func TestUpdateKustomizationResourcesSimple_AddDuplicate(t *testing.T) {
	// Create temp directory
	tmpDir, err := os.MkdirTemp("", "test-kustomization-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()
	kustomizationPath := "kustomization.yaml"

	// Create initial kustomization with a resource
	initialKustomization := kustypes.Kustomization{
		TypeMeta: kustypes.TypeMeta{
			APIVersion: "kustomize.config.k8s.io/v1beta1",
			Kind:       "Kustomization",
		},
		Resources: []string{"policy1.yaml"},
	}
	initialContent, err := yaml.Marshal(initialKustomization)
	require.NoError(t, err)

	fullPath := filepath.Join(tmpDir, kustomizationPath)
	err = os.WriteFile(fullPath, initialContent, 0644)
	require.NoError(t, err)

	// Try to add the same resource again
	resourcePath := "policy1.yaml"
	err = updateKustomizationResourcesSimple(nil, ctx, tmpDir, kustomizationPath, resourcePath, true)
	require.NoError(t, err)

	// Verify no duplicates
	content, err := os.ReadFile(fullPath)
	require.NoError(t, err)

	var kustomization kustypes.Kustomization
	err = yaml.Unmarshal(content, &kustomization)
	require.NoError(t, err)

	// Count occurrences
	count := 0
	for _, res := range kustomization.Resources {
		if res == resourcePath {
			count++
		}
	}
	assert.Equal(t, 1, count, "resource should appear only once")
}

// TestUpdateKustomizationResourcesSimple_Sorting tests alphabetical sorting
func TestUpdateKustomizationResourcesSimple_Sorting(t *testing.T) {
	// Create temp directory
	tmpDir, err := os.MkdirTemp("", "test-kustomization-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()
	kustomizationPath := "kustomization.yaml"

	// Create initial kustomization
	err = ensureKustomizationExistsSimple(nil, ctx, tmpDir, kustomizationPath)
	require.NoError(t, err)

	// Add resources in random order
	resources := []string{"policy-z.yaml", "policy-a.yaml", "policy-m.yaml"}
	for _, res := range resources {
		err = updateKustomizationResourcesSimple(nil, ctx, tmpDir, kustomizationPath, res, true)
		require.NoError(t, err)
	}

	// Verify resources are sorted
	fullPath := filepath.Join(tmpDir, kustomizationPath)
	content, err := os.ReadFile(fullPath)
	require.NoError(t, err)

	var kustomization kustypes.Kustomization
	err = yaml.Unmarshal(content, &kustomization)
	require.NoError(t, err)

	expected := []string{"policy-a.yaml", "policy-m.yaml", "policy-z.yaml"}
	assert.Equal(t, expected, kustomization.Resources)
}

// TestUpdateKustomizationResourcesSimple_RelativePath tests relative path handling
func TestUpdateKustomizationResourcesSimple_RelativePath(t *testing.T) {
	// Create temp directory
	tmpDir, err := os.MkdirTemp("", "test-kustomization-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()
	
	// Create nested directory structure
	clusterDir := filepath.Join("cluster", "namespace")
	err = os.MkdirAll(filepath.Join(tmpDir, clusterDir), 0755)
	require.NoError(t, err)

	kustomizationPath := filepath.Join(clusterDir, "kustomization.yaml")

	// Create initial kustomization
	err = ensureKustomizationExistsSimple(nil, ctx, tmpDir, kustomizationPath)
	require.NoError(t, err)

	// Add resource with relative path
	resourcePath := "policies/policy1.yaml"
	err = updateKustomizationResourcesSimple(nil, ctx, tmpDir, kustomizationPath, resourcePath, true)
	require.NoError(t, err)

	// Verify resource path is preserved
	fullPath := filepath.Join(tmpDir, kustomizationPath)
	content, err := os.ReadFile(fullPath)
	require.NoError(t, err)

	var kustomization kustypes.Kustomization
	err = yaml.Unmarshal(content, &kustomization)
	require.NoError(t, err)

	assert.Contains(t, kustomization.Resources, resourcePath)
}

// TestUpdateKustomizationResourcesSimple_RemoveNonExistent tests removing non-existent resource
func TestUpdateKustomizationResourcesSimple_RemoveNonExistent(t *testing.T) {
	// Create temp directory
	tmpDir, err := os.MkdirTemp("", "test-kustomization-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()
	kustomizationPath := "kustomization.yaml"

	// Create initial kustomization with resources
	initialKustomization := kustypes.Kustomization{
		TypeMeta: kustypes.TypeMeta{
			APIVersion: "kustomize.config.k8s.io/v1beta1",
			Kind:       "Kustomization",
		},
		Resources: []string{"policy1.yaml", "policy2.yaml"},
	}
	initialContent, err := yaml.Marshal(initialKustomization)
	require.NoError(t, err)

	fullPath := filepath.Join(tmpDir, kustomizationPath)
	err = os.WriteFile(fullPath, initialContent, 0644)
	require.NoError(t, err)

	// Try to remove non-existent resource (should not error)
	resourcePath := "policy-does-not-exist.yaml"
	err = updateKustomizationResourcesSimple(nil, ctx, tmpDir, kustomizationPath, resourcePath, false)
	require.NoError(t, err)

	// Verify original resources are still there
	content, err := os.ReadFile(fullPath)
	require.NoError(t, err)

	var kustomization kustypes.Kustomization
	err = yaml.Unmarshal(content, &kustomization)
	require.NoError(t, err)

	assert.Contains(t, kustomization.Resources, "policy1.yaml")
	assert.Contains(t, kustomization.Resources, "policy2.yaml")
	assert.Len(t, kustomization.Resources, 2)
}

// TestUpdateKustomizationResourcesSimple_MultipleOperations tests multiple add/remove operations
func TestUpdateKustomizationResourcesSimple_MultipleOperations(t *testing.T) {
	// Create temp directory
	tmpDir, err := os.MkdirTemp("", "test-kustomization-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()
	kustomizationPath := "kustomization.yaml"

	// Create initial kustomization
	err = ensureKustomizationExistsSimple(nil, ctx, tmpDir, kustomizationPath)
	require.NoError(t, err)

	// Add multiple resources
	resources := []string{"policy1.yaml", "policy2.yaml", "policy3.yaml", "policy4.yaml"}
	for _, res := range resources {
		err = updateKustomizationResourcesSimple(nil, ctx, tmpDir, kustomizationPath, res, true)
		require.NoError(t, err)
	}

	// Remove some resources
	err = updateKustomizationResourcesSimple(nil, ctx, tmpDir, kustomizationPath, "policy2.yaml", false)
	require.NoError(t, err)
	err = updateKustomizationResourcesSimple(nil, ctx, tmpDir, kustomizationPath, "policy4.yaml", false)
	require.NoError(t, err)

	// Add a new resource
	err = updateKustomizationResourcesSimple(nil, ctx, tmpDir, kustomizationPath, "policy5.yaml", true)
	require.NoError(t, err)

	// Verify final state
	fullPath := filepath.Join(tmpDir, kustomizationPath)
	content, err := os.ReadFile(fullPath)
	require.NoError(t, err)

	var kustomization kustypes.Kustomization
	err = yaml.Unmarshal(content, &kustomization)
	require.NoError(t, err)

	expected := []string{"policy1.yaml", "policy3.yaml", "policy5.yaml"}
	assert.Equal(t, expected, kustomization.Resources)
}

// TestUpdateKustomizationResourcesSimple_EmptyResources tests handling empty resources list
func TestUpdateKustomizationResourcesSimple_EmptyResources(t *testing.T) {
	// Create temp directory
	tmpDir, err := os.MkdirTemp("", "test-kustomization-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()
	kustomizationPath := "kustomization.yaml"

	// Create kustomization with resources
	initialKustomization := kustypes.Kustomization{
		TypeMeta: kustypes.TypeMeta{
			APIVersion: "kustomize.config.k8s.io/v1beta1",
			Kind:       "Kustomization",
		},
		Resources: []string{"policy1.yaml"},
	}
	initialContent, err := yaml.Marshal(initialKustomization)
	require.NoError(t, err)

	fullPath := filepath.Join(tmpDir, kustomizationPath)
	err = os.WriteFile(fullPath, initialContent, 0644)
	require.NoError(t, err)

	// Remove the only resource
	err = updateKustomizationResourcesSimple(nil, ctx, tmpDir, kustomizationPath, "policy1.yaml", false)
	require.NoError(t, err)

	// Verify resources list is empty
	content, err := os.ReadFile(fullPath)
	require.NoError(t, err)

	var kustomization kustypes.Kustomization
	err = yaml.Unmarshal(content, &kustomization)
	require.NoError(t, err)

	assert.Empty(t, kustomization.Resources)
}

// Benchmark tests for performance monitoring
func BenchmarkEnsureKustomizationExistsSimple(b *testing.B) {
	tmpDir, err := os.MkdirTemp("", "bench-kustomization-*")
	if err != nil {
		b.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		kustomizationPath := filepath.Join("test", "kustomization.yaml")
		os.MkdirAll(filepath.Join(tmpDir, "test"), 0755)
		_ = ensureKustomizationExistsSimple(nil, ctx, tmpDir, kustomizationPath)
	}
}

func BenchmarkUpdateKustomizationResourcesSimple_Add(b *testing.B) {
	tmpDir, err := os.MkdirTemp("", "bench-kustomization-*")
	if err != nil {
		b.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	ctx := context.Background()
	kustomizationPath := "kustomization.yaml"

	// Setup
	_ = ensureKustomizationExistsSimple(nil, ctx, tmpDir, kustomizationPath)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		resourcePath := filepath.Join("policies", "policy.yaml")
		_ = updateKustomizationResourcesSimple(nil, ctx, tmpDir, kustomizationPath, resourcePath, true)
	}
}

