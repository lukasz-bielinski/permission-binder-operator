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
	"encoding/json"
	"fmt"
	"path/filepath"

	networkingv1 "k8s.io/api/networking/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/yaml"
)

// processTemplate processes template using Go object manipulation (recommended approach)
// 1. Read template YAML file
// 2. Parse YAML → Go Object (yaml.Unmarshal)
// 3. Modify Go Object (metadata.name, metadata.namespace, annotations)
// 4. Validate using Kubernetes dry-run
// 5. Convert Go Object → YAML (yaml.Marshal)
func processTemplate(r ReconcilerInterface, 
	ctx context.Context,
	repoDir string,
	templateDir string,
	templateName string,
	namespace string,
	clusterName string,
) ([]byte, error) {
	logger := log.FromContext(ctx)

	// Step 1: Read template file
	templatePath := filepath.Join(templateDir, templateName)
	templateContent, err := readFile(repoDir, templatePath)
	if err != nil {
		return nil, fmt.Errorf("failed to read template: %w", err)
	}

	// Step 2: Parse YAML → Go Object
	var policy networkingv1.NetworkPolicy
	if err := yaml.Unmarshal(templateContent, &policy); err != nil {
		return nil, fmt.Errorf("failed to parse template: %w", err)
	}

	// Step 3: Validate template using dry-run first
	dryRunPolicy := policy.DeepCopy()
	dryRunPolicy.Name = fmt.Sprintf("dry-run-%s-%d", templateName, 0)
	dryRunPolicy.Namespace = "default"
	if err := r.Create(ctx, dryRunPolicy, client.DryRunAll); err != nil {
		return nil, fmt.Errorf("template validation failed: %w", err)
	}

	// Step 4: Modify Go Object
	// Get new policy name
	policyName := getNetworkPolicyName(namespace, templateName)

	// Modify metadata.name
	policy.Name = policyName

	// Modify metadata.namespace
	policy.Namespace = namespace

	// Add annotations (merge with existing if any)
	if policy.Annotations == nil {
		policy.Annotations = make(map[string]string)
	}
	policy.Annotations[AnnotationTemplate] = templateName
	policy.Annotations[AnnotationTemplatePath] = filepath.Join(templateDir, templateName)
	policy.Annotations[AnnotationTemplateVersion] = "HEAD" // Simplified - could get from git log if needed

	// Step 5: Final dry-run validation
	if err := r.Create(ctx, &policy, client.DryRunAll); err != nil {
		return nil, fmt.Errorf("modified template validation failed: %w", err)
	}

	// Step 6: Convert Go Object → JSON (easier to manipulate)
	jsonBytes, err := json.Marshal(&policy)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal policy to JSON: %w", err)
	}

	// Step 7: Parse JSON to map for manipulation
	var jsonObj map[string]interface{}
	if err := json.Unmarshal(jsonBytes, &jsonObj); err != nil {
		return nil, fmt.Errorf("failed to unmarshal JSON: %w", err)
	}

	// Step 8: Clean JSON object (remove internal Kubernetes fields, ensure apiVersion/kind)
	cleanJSONForGitOps(jsonObj)

	// Step 9: Convert cleaned JSON → YAML
	cleanJSONBytes, err := json.Marshal(jsonObj)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal cleaned JSON: %w", err)
	}

	yamlContent, err := yaml.JSONToYAML(cleanJSONBytes)
	if err != nil {
		return nil, fmt.Errorf("failed to convert JSON to YAML: %w", err)
	}

	logger.V(1).Info("Processed template", "template", templateName, "namespace", namespace, "policyName", policyName)
	return yamlContent, nil
}

// cleanJSONForGitOps cleans JSON object for GitOps (inspired by kubectl-neat)
// Removes internal Kubernetes fields and ensures proper structure
func cleanJSONForGitOps(obj map[string]interface{}) {
	// Ensure apiVersion and kind are at top level
	if obj["apiVersion"] == nil {
		obj["apiVersion"] = "networking.k8s.io/v1"
	}
	if obj["kind"] == nil {
		obj["kind"] = "NetworkPolicy"
	}

	// Clean metadata section
	if metadata, ok := obj["metadata"].(map[string]interface{}); ok {
		// Remove internal Kubernetes fields
		fieldsToRemove := []string{
			"managedFields",
			"creationTimestamp",
			"generation",
			"uid",
			"resourceVersion",
			"selfLink",
		}
		for _, field := range fieldsToRemove {
			delete(metadata, field)
		}

		// Clean annotations (remove internal Kubernetes annotations)
		if annotations, ok := metadata["annotations"].(map[string]interface{}); ok {
			for key := range annotations {
				if isInternalKubernetesAnnotation(key) {
					delete(annotations, key)
				}
			}
			// Remove annotations if empty
			if len(annotations) == 0 {
				delete(metadata, "annotations")
			}
		}

		// Remove labels if empty
		if labels, ok := metadata["labels"].(map[string]interface{}); ok && len(labels) == 0 {
			delete(metadata, "labels")
		}
	}

	// Remove status if present (shouldn't be in GitOps manifests)
	delete(obj, "status")
}

// isInternalKubernetesAnnotation checks if annotation is internal to Kubernetes
// Inspired by kubectl-neat: filters out system-managed annotations
func isInternalKubernetesAnnotation(key string) bool {
	internalPrefixes := []string{
		"kubectl.kubernetes.io/",
		"deployment.kubernetes.io/",
		"pod-template-hash",
		"kubernetes.io/",
	}
	for _, prefix := range internalPrefixes {
		if len(key) >= len(prefix) && key[:len(prefix)] == prefix {
			return true
		}
	}
	return false
}

// getAllTemplates lists all YAML files in template directory
func getAllTemplates(r ReconcilerInterface, repoDir string, templateDir string) ([]string, error) {
	return listFiles(repoDir, templateDir)
}

