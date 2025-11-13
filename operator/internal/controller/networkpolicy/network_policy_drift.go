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
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8syaml "k8s.io/apimachinery/pkg/util/yaml"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

func normalizeNetworkPolicySpec(spec networkingv1.NetworkPolicySpec) []byte {
	// Create a normalized spec with only rules (no metadata)
	normalized := struct {
		PodSelector map[string]interface{}                  `json:"podSelector"`
		PolicyTypes []networkingv1.PolicyType               `json:"policyTypes"`
		Ingress     []networkingv1.NetworkPolicyIngressRule `json:"ingress,omitempty"`
		Egress      []networkingv1.NetworkPolicyEgressRule  `json:"egress,omitempty"`
	}{
		PodSelector: normalizeSelector(spec.PodSelector),
		PolicyTypes: spec.PolicyTypes,
		Ingress:     normalizeIngressRules(spec.Ingress),
		Egress:      normalizeEgressRules(spec.Egress),
	}

	jsonBytes, _ := json.Marshal(normalized)
	return jsonBytes
}

// normalizeSelector normalizes a label selector for comparison
func normalizeSelector(selector metav1.LabelSelector) map[string]interface{} {
	result := make(map[string]interface{})

	// Sort matchLabels
	if len(selector.MatchLabels) > 0 {
		labels := make(map[string]string)
		keys := make([]string, 0, len(selector.MatchLabels))
		for k := range selector.MatchLabels {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			labels[k] = selector.MatchLabels[k]
		}
		result["matchLabels"] = labels
	}

	// Sort matchExpressions
	if len(selector.MatchExpressions) > 0 {
		exprs := make([]interface{}, len(selector.MatchExpressions))
		for i, expr := range selector.MatchExpressions {
			exprs[i] = map[string]interface{}{
				"key":      expr.Key,
				"operator": expr.Operator,
				"values":   sort.StringSlice(expr.Values),
			}
		}
		result["matchExpressions"] = exprs
	}

	return result
}

// normalizeIngressRules normalizes ingress rules for comparison
func normalizeIngressRules(rules []networkingv1.NetworkPolicyIngressRule) []networkingv1.NetworkPolicyIngressRule {
	normalized := make([]networkingv1.NetworkPolicyIngressRule, len(rules))
	for i, rule := range rules {
		normalized[i] = networkingv1.NetworkPolicyIngressRule{
			Ports: normalizePorts(rule.Ports),
			From:  normalizeNetworkPolicyPeers(rule.From),
		}
	}
	// Sort rules by normalized JSON representation
	sort.Slice(normalized, func(i, j int) bool {
		iJSON, _ := json.Marshal(normalized[i])
		jJSON, _ := json.Marshal(normalized[j])
		return string(iJSON) < string(jJSON)
	})
	return normalized
}

// normalizeEgressRules normalizes egress rules for comparison
func normalizeEgressRules(rules []networkingv1.NetworkPolicyEgressRule) []networkingv1.NetworkPolicyEgressRule {
	normalized := make([]networkingv1.NetworkPolicyEgressRule, len(rules))
	for i, rule := range rules {
		normalized[i] = networkingv1.NetworkPolicyEgressRule{
			Ports: normalizePorts(rule.Ports),
			To:    normalizeNetworkPolicyPeers(rule.To),
		}
	}
	// Sort rules by normalized JSON representation
	sort.Slice(normalized, func(i, j int) bool {
		iJSON, _ := json.Marshal(normalized[i])
		jJSON, _ := json.Marshal(normalized[j])
		return string(iJSON) < string(jJSON)
	})
	return normalized
}

// normalizeNetworkPolicyPeers normalizes network policy peers for comparison
func normalizeNetworkPolicyPeers(peers []networkingv1.NetworkPolicyPeer) []networkingv1.NetworkPolicyPeer {
	normalized := make([]networkingv1.NetworkPolicyPeer, len(peers))
	for i, peer := range peers {
		normalized[i] = networkingv1.NetworkPolicyPeer{
			PodSelector:       peer.PodSelector,
			NamespaceSelector: peer.NamespaceSelector,
			IPBlock:           peer.IPBlock,
		}
	}
	// Sort peers by normalized JSON representation
	sort.Slice(normalized, func(i, j int) bool {
		iJSON, _ := json.Marshal(normalized[i])
		jJSON, _ := json.Marshal(normalized[j])
		return string(iJSON) < string(jJSON)
	})
	return normalized
}

// normalizePorts normalizes network policy ports for comparison
func normalizePorts(ports []networkingv1.NetworkPolicyPort) []networkingv1.NetworkPolicyPort {
	normalized := make([]networkingv1.NetworkPolicyPort, len(ports))
	copy(normalized, ports)
	// Sort ports
	sort.Slice(normalized, func(i, j int) bool {
		iJSON, _ := json.Marshal(normalized[i])
		jJSON, _ := json.Marshal(normalized[j])
		return string(iJSON) < string(jJSON)
	})
	return normalized
}

// calculateRulesHash calculates SHA256 hash of NetworkPolicy rules (spec only)
func calculateRulesHash(spec networkingv1.NetworkPolicySpec) string {
	normalized := normalizeNetworkPolicySpec(spec)
	hash := sha256.Sum256(normalized)
	return hex.EncodeToString(hash[:])
}

// compareNetworkPolicyRules compares two NetworkPolicy specs (rules only, ignoring metadata)
func compareNetworkPolicyRules(spec1 networkingv1.NetworkPolicySpec, spec2 networkingv1.NetworkPolicySpec) bool {
	hash1 := calculateRulesHash(spec1)
	hash2 := calculateRulesHash(spec2)
	return hash1 == hash2
}

// compareNetworkPolicy compares cluster NetworkPolicy with Git file (rules only)
func compareNetworkPolicy(r ReconcilerInterface,
	ctx context.Context,
	clusterPolicy *networkingv1.NetworkPolicy,
	gitContent []byte,
) (bool, error) {
	// Parse Git policy
	var gitPolicy networkingv1.NetworkPolicy
	if err := k8syaml.Unmarshal(gitContent, &gitPolicy); err != nil {
		return false, fmt.Errorf("failed to parse Git policy: %w", err)
	}

	// Compare rules only (ignore metadata)
	return compareNetworkPolicyRules(clusterPolicy.Spec, gitPolicy.Spec), nil
}

// checkDriftForNamespace checks if NetworkPolicy in cluster differs from Git (rules-only comparison)
func checkDriftForNamespace(r ReconcilerInterface,
	ctx context.Context,
	permissionBinder *permissionv1.PermissionBinder,
	namespace string,
) error {
	logger := log.FromContext(ctx)

	gitRepo := permissionBinder.Spec.NetworkPolicy.GitRepository
	clusterName := gitRepo.ClusterName

	// Get TLS verify setting (default: true for security)
	tlsVerify := true
	if gitRepo.GitTlsVerify != nil {
		tlsVerify = *gitRepo.GitTlsVerify
	}

	// Get Git credentials
	credentials, err := getGitCredentials(r, ctx, gitRepo.CredentialsSecretRef)
	if err != nil {
		return fmt.Errorf("failed to get Git credentials: %w", err)
	}

	// Clone repo
	tmpDir, err := cloneGitRepo(ctx, gitRepo.URL, credentials, tlsVerify)
	if err != nil {
		return fmt.Errorf("failed to clone repository: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	// Get all NetworkPolicies from namespace
	var policyList networkingv1.NetworkPolicyList
	if err := r.List(ctx, &policyList, client.InNamespace(namespace)); err != nil {
		return fmt.Errorf("failed to get cluster policies: %w", err)
	}
	clusterPolicies := policyList.Items

	// Check each policy for drift
	for _, clusterPolicy := range clusterPolicies {
		// Determine file path
		var filePath string
		if clusterPolicy.Annotations != nil && clusterPolicy.Annotations[AnnotationTemplate] != "" {
			// Template-based policy
			fileName := fmt.Sprintf("%s-%s.yaml", namespace, strings.TrimSuffix(clusterPolicy.Annotations[AnnotationTemplate], ".yaml"))
			filePath = getNetworkPolicyFilePath(clusterName, namespace, fileName)
		} else {
			// Other policy
			filePath = getNetworkPolicyFilePath(clusterName, namespace, fmt.Sprintf("%s.yaml", clusterPolicy.Name))
		}

		// Check if file exists in Git
		if !fileExists(tmpDir, filePath) {
			// File doesn't exist - this is handled by normal processing
			continue
		}

		// Read file from Git
		gitContent, err := readFile(tmpDir, filePath)
		if err != nil {
			logger.Error(err, "Failed to read file from Git", "filePath", filePath)
			continue
		}

		// Compare rules only
		identical, err := compareNetworkPolicy(r, ctx, &clusterPolicy, gitContent)
		if err != nil {
			logger.Error(err, "Failed to compare policies", "filePath", filePath)
			continue
		}

		if !identical {
			// Rules differ - drift detected
			logger.Info("Drift detected for NetworkPolicy",
				"namespace", namespace,
				"policyName", clusterPolicy.Name,
				"filePath", filePath,
				"action", "networkpolicy_drift_detected",
				"audit_trail", true)

			// Update status to indicate drift
			// This will trigger PR creation in next reconciliation
			// Status update will be handled by main reconciliation logic
		} else {
			// Rules identical - no action needed (CRITICAL: no iptables reload)
			logger.V(1).Info("Rules identical, skipping (no iptables reload)",
				"namespace", namespace,
				"policyName", clusterPolicy.Name,
				"filePath", filePath)
		}
	}

	return nil
}
