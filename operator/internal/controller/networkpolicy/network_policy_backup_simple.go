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

	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/yaml"
)

// backupNetworkPolicy gets NetworkPolicy from cluster and converts to YAML
// Uses native k8s client: kubectl get networkpolicy -o json
func backupNetworkPolicy(r ReconcilerInterface, 
	ctx context.Context,
	namespace string,
	policyName string,
) ([]byte, error) {
	logger := log.FromContext(ctx)

	// Get policy from cluster using native k8s client
	var policy networkingv1.NetworkPolicy
	if err := r.Get(ctx, types.NamespacedName{
		Name:      policyName,
		Namespace: namespace,
	}, &policy); err != nil {
		return nil, fmt.Errorf("failed to get NetworkPolicy: %w", err)
	}

	// Step 1: Convert Go Object → JSON (easier to manipulate)
	jsonBytes, err := json.Marshal(&policy)
	if err != nil {
		logger.Error(err, "Failed to marshal policy to JSON", "policy", policyName)
		return nil, fmt.Errorf("failed to marshal policy to JSON: %w", err)
	}

	// Step 2: Parse JSON to map for manipulation
	var jsonObj map[string]interface{}
	if err := json.Unmarshal(jsonBytes, &jsonObj); err != nil {
		logger.Error(err, "Failed to unmarshal JSON", "policy", policyName)
		return nil, fmt.Errorf("failed to unmarshal JSON: %w", err)
	}

	// Step 3: Clean JSON object (remove internal Kubernetes fields, ensure apiVersion/kind)
	cleanJSONForGitOps(jsonObj)

	// Step 4: Convert cleaned JSON → YAML
	cleanJSONBytes, err := json.Marshal(jsonObj)
	if err != nil {
		logger.Error(err, "Failed to marshal cleaned JSON", "policy", policyName)
		return nil, fmt.Errorf("failed to marshal cleaned JSON: %w", err)
	}

	yamlBytes, err := yaml.JSONToYAML(cleanJSONBytes)
	if err != nil {
		logger.Error(err, "Failed to convert JSON to YAML", "policy", policyName)
		return nil, fmt.Errorf("failed to convert JSON to YAML: %w", err)
	}

	logger.V(1).Info("Backed up NetworkPolicy", "namespace", namespace, "policy", policyName)
	return yamlBytes, nil
}

