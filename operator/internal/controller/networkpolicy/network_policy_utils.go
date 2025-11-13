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
	"fmt"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// detectGitProvider detects Git provider from URL or uses explicit provider
func detectGitProvider(repoURL string, explicitProvider string) (string, error) {
	// If explicit provider is provided, use it (for self-hosted)
	if explicitProvider != "" {
		return explicitProvider, nil
	}

	// Auto-discovery from URL (for public providers)
	if strings.Contains(repoURL, "bitbucket.org") {
		return "bitbucket", nil
	} else if strings.Contains(repoURL, "github.com") {
		return "github", nil
	} else if strings.Contains(repoURL, "gitlab.com") || strings.Contains(repoURL, "gitlab.") {
		return "gitlab", nil
	}

	// For self-hosted - provider must be explicitly specified
	return "", fmt.Errorf("cannot auto-detect git provider from URL: %s. Please specify 'provider' explicitly in CR spec", repoURL)
}

// getAPIBaseURL returns the API base URL for Git provider
func getAPIBaseURL(provider string, customAPIBaseURL string, repoURL string) string {
	// If custom API base URL is provided, use it
	if customAPIBaseURL != "" {
		return customAPIBaseURL
	}

	// Standard API endpoints for public providers
	switch provider {
	case "bitbucket":
		return "https://api.bitbucket.org/2.0"
	case "github":
		return "https://api.github.com"
	case "gitlab":
		return "https://gitlab.com/api/v4"
	default:
		// For self-hosted - extract base URL from repo URL
		u, err := url.Parse(repoURL)
		if err != nil {
			return ""
		}
		baseURL := fmt.Sprintf("%s://%s", u.Scheme, u.Host)

		// Default API paths for self-hosted
		switch provider {
		case "bitbucket":
			return fmt.Sprintf("%s/rest/api/1.0", baseURL)
		case "github":
			return fmt.Sprintf("%s/api/v3", baseURL)
		case "gitlab":
			return fmt.Sprintf("%s/api/v4", baseURL)
		}
		return baseURL
	}
}

// extractWorkspaceFromURL extracts workspace from Bitbucket URL
func extractWorkspaceFromURL(repoURL string) (string, error) {
	u, err := url.Parse(repoURL)
	if err != nil {
		return "", err
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) >= 1 {
		return parts[0], nil // workspace
	}
	return "", fmt.Errorf("cannot extract workspace from URL: %s", repoURL)
}

// extractRepositoryFromURL extracts repository name from URL
func extractRepositoryFromURL(repoURL string) string {
	u, err := url.Parse(repoURL)
	if err != nil {
		return ""
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) >= 2 {
		repo := parts[1]
		// Remove .git suffix if exists
		repo = strings.TrimSuffix(repo, ".git")
		return repo
	}
	return ""
}

// IsNamespaceExcluded checks if a namespace is excluded from NetworkPolicy operations.
//
// A namespace is excluded if:
//   - It matches any name in excludeList.Explicit
//   - It matches any pattern in excludeList.Patterns (regex)
//
// This function is used to implement the global exclude list that blocks ALL
// NetworkPolicy operations (template processing and backup) for excluded namespaces.
//
// Parameters:
//   - namespace: The namespace name to check
//   - excludeList: The exclude list configuration (can be nil)
//
// Returns:
//   - bool: true if namespace is excluded, false otherwise
//
// Example:
//
//	excludeList := &permissionv1.NamespaceExcludeList{
//	    Explicit: []string{"kube-system", "kube-public"},
//	    Patterns: []string{"^test-.*"},
//	}
//	if IsNamespaceExcluded("test-ns", excludeList) {
//	    return // Skip processing
//	}
func IsNamespaceExcluded(namespace string, excludeList *permissionv1.NamespaceExcludeList) bool {
	if excludeList == nil {
		return false
	}

	// Check explicit names
	for _, explicit := range excludeList.Explicit {
		if namespace == explicit {
			return true
		}
	}

	// Check patterns
	for _, pattern := range excludeList.Patterns {
		matched, err := regexp.MatchString(pattern, namespace)
		if err != nil {
			// Invalid regex - skip
			continue
		}
		if matched {
			return true
		}
	}

	return false
}

// isNamespaceExcludedFromBackup checks if namespace is excluded from backup (per-namespace exclude list)
func isNamespaceExcludedFromBackup(namespace string, excludeList *permissionv1.NamespaceExcludeList) bool {
	if excludeList == nil {
		return false
	}

	// Check explicit names
	for _, explicit := range excludeList.Explicit {
		if namespace == explicit {
			return true
		}
	}

	// Check patterns
	for _, pattern := range excludeList.Patterns {
		matched, err := regexp.MatchString(pattern, namespace)
		if err != nil {
			// Invalid regex - skip
			continue
		}
		if matched {
			return true
		}
	}

	return false
}

// getNetworkPolicyName returns the NetworkPolicy name for template-based policies
func getNetworkPolicyName(namespace string, templateName string) string {
	templateBaseName := strings.TrimSuffix(templateName, ".yaml")
	return fmt.Sprintf("%s-%s", namespace, templateBaseName)
}

// isPolicyFromTemplate checks if policy name matches template pattern
func isPolicyFromTemplate(policyName string, namespace string, templateName string) bool {
	expectedName := getNetworkPolicyName(namespace, templateName)
	return policyName == expectedName
}

// generateBranchName generates a unique branch name for NetworkPolicy PR
func generateBranchName(clusterName string, namespace string) string {
	return fmt.Sprintf("networkpolicy/%s/%s", clusterName, namespace)
}

// getNetworkPolicyFilePath returns the Git file path for a NetworkPolicy
func getNetworkPolicyFilePath(clusterName string, namespace string, fileName string) string {
	return filepath.Join("networkpolicies", clusterName, namespace, fileName)
}

// shouldBackupExistingPolicy checks if an existing policy should be backed up
func shouldBackupExistingPolicy(
	namespace string,
	backupExisting bool,
	excludeBackupForNamespaces *permissionv1.NamespaceExcludeList,
) bool {
	if !backupExisting {
		return false
	}

	// Check if namespace is excluded from backup
	if isNamespaceExcludedFromBackup(namespace, excludeBackupForNamespaces) {
		return false
	}

	return true
}

// chunkNamespaces splits namespaces into batches for processing
func chunkNamespaces(namespaces []string, batchSize int) [][]string {
	if batchSize <= 0 {
		batchSize = defaultBatchSize
	}

	var batches [][]string
	for i := 0; i < len(namespaces); i += batchSize {
		end := i + batchSize
		if end > len(namespaces) {
			end = len(namespaces)
		}
		batches = append(batches, namespaces[i:end])
	}

	return batches
}

// handleRateLimitError handles Git API rate limit errors
func handleRateLimitError(err error) bool {
	if err == nil {
		return false
	}

	errStr := err.Error()
	return strings.Contains(errStr, "429") || strings.Contains(errStr, "rate limit") || strings.Contains(errStr, "too many requests")
}
