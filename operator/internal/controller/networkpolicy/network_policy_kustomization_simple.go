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
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"sigs.k8s.io/controller-runtime/pkg/log"
	kustypes "sigs.k8s.io/kustomize/api/types"
	"sigs.k8s.io/yaml"
)

func ensureKustomizationExistsSimple(r ReconcilerInterface,
	ctx context.Context,
	repoDir string,
	kustomizationPath string,
) error {
	logger := log.FromContext(ctx)

	// Check if kustomization.yaml exists
	fullPath := filepath.Join(repoDir, kustomizationPath)
	if _, err := os.Stat(fullPath); err == nil {
		// Already exists
		return nil
	}

	// Create new kustomization.yaml
	kustomization := kustypes.Kustomization{
		TypeMeta: kustypes.TypeMeta{
			APIVersion: "kustomize.config.k8s.io/v1beta1",
			Kind:       "Kustomization",
		},
		Resources: []string{},
	}

	// Marshal to YAML
	yamlContent, err := yaml.Marshal(kustomization)
	if err != nil {
		return fmt.Errorf("failed to marshal kustomization: %w", err)
	}

	// Write file
	if err := writeFile(repoDir, kustomizationPath, yamlContent); err != nil {
		return fmt.Errorf("failed to write kustomization: %w", err)
	}

	logger.Info("Created kustomization.yaml", "path", kustomizationPath)
	return nil
}

// updateKustomizationResourcesSimple adds or removes a resource from kustomization.yaml
func updateKustomizationResourcesSimple(r ReconcilerInterface,
	ctx context.Context,
	repoDir string,
	kustomizationPath string,
	resourcePath string,
	add bool,
) error {
	logger := log.FromContext(ctx)

	// Read existing kustomization
	content, err := readFile(repoDir, kustomizationPath)
	if err != nil {
		return fmt.Errorf("failed to read kustomization: %w", err)
	}

	// Parse kustomization
	var kustomization kustypes.Kustomization
	if err := yaml.Unmarshal(content, &kustomization); err != nil {
		return fmt.Errorf("failed to parse kustomization: %w", err)
	}

	// resourcePath is already relative to kustomization.yaml directory
	// (calculated in reconciliation_single.go or reconciliation_cleanup.go)
	// If it's an absolute path, calculate relative path; otherwise use as-is
	var relPath string
	if filepath.IsAbs(resourcePath) {
		// Absolute path - calculate relative path
		baseDir := filepath.Dir(kustomizationPath)
		var err error
		relPath, err = filepath.Rel(baseDir, resourcePath)
		if err != nil {
			relPath = resourcePath // Fallback to original path
		}
	} else {
		// Already relative path - use as-is
		relPath = resourcePath
	}

	// Add or remove resource
	found := false
	for i, res := range kustomization.Resources {
		if res == relPath {
			found = true
			if !add {
				// Remove resource
				kustomization.Resources = append(kustomization.Resources[:i], kustomization.Resources[i+1:]...)
			}
			break
		}
	}

	if add && !found {
		// Add resource
		kustomization.Resources = append(kustomization.Resources, relPath)
	}

	// Sort resources alphabetically
	sort.Strings(kustomization.Resources)

	// Remove duplicates
	uniqueResources := make([]string, 0)
	seen := make(map[string]bool)
	for _, res := range kustomization.Resources {
		if !seen[res] {
			seen[res] = true
			uniqueResources = append(uniqueResources, res)
		}
	}
	kustomization.Resources = uniqueResources

	// Marshal back to YAML
	yamlContent, err := yaml.Marshal(kustomization)
	if err != nil {
		return fmt.Errorf("failed to marshal kustomization: %w", err)
	}

	// Write back
	if err := writeFile(repoDir, kustomizationPath, yamlContent); err != nil {
		return fmt.Errorf("failed to write kustomization: %w", err)
	}

	action := "added"
	if !add {
		action = "removed"
	}
	logger.V(1).Info("Updated kustomization.yaml", "path", kustomizationPath, "resource", relPath, "action", action)
	return nil
}
