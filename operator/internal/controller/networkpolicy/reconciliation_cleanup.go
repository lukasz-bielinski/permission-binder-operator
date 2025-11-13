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

	"sigs.k8s.io/controller-runtime/pkg/log"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// ProcessRemovedNamespaces handles cleanup for namespaces that were removed from the whitelist.
//
// When a namespace is removed from the PermissionBinder whitelist, this function:
//   - Removes NetworkPolicy files from Git repository
//   - Creates a Pull Request for the removal
//   - Updates the namespace status to "removed"
//   - Sets the RemovedAt timestamp for retention tracking
//
// The function processes all namespaces that are no longer in currentNamespaces
// but still have a status entry (and are not already marked as "removed").
//
// Parameters:
//   - ctx: Context for cancellation and timeout
//   - r: ReconcilerInterface for Kubernetes API access
//   - permissionBinder: The PermissionBinder CR containing configuration
//   - currentNamespaces: Map of currently whitelisted namespaces (namespace -> true)
//
// Returns:
//   - error: Returns an error if cleanup fails, nil on success
//
// Example:
//
//	currentNamespaces := map[string]bool{"ns1": true, "ns2": true}
//	err := ProcessRemovedNamespaces(ctx, reconciler, binder, currentNamespaces)
//	if err != nil {
//	    logger.Error(err, "Failed to process removed namespaces")
//	}
func ProcessRemovedNamespaces(
	ctx context.Context,
	r ReconcilerInterface,
	permissionBinder *permissionv1.PermissionBinder,
	currentNamespaces map[string]bool,
) error {
	logger := log.FromContext(ctx)

	// Find namespaces that were removed
	removedNamespaces := make([]string, 0)
	for _, status := range permissionBinder.Status.NetworkPolicies {
		if !currentNamespaces[status.Namespace] && status.State != "removed" {
			removedNamespaces = append(removedNamespaces, status.Namespace)
		}
	}

	if len(removedNamespaces) == 0 {
		return nil
	}

	logger.Info("Processing removed namespaces",
		"count", len(removedNamespaces))

	gitRepo := permissionBinder.Spec.NetworkPolicy.GitRepository
	clusterName := gitRepo.ClusterName
	baseBranch := gitRepo.BaseBranch

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

	// Process each removed namespace
	for _, namespace := range removedNamespaces {
		// Clone repo
		tmpDir, err := cloneGitRepo(ctx, gitRepo.URL, credentials, tlsVerify)
		if err != nil {
			logger.Error(err, "Failed to clone repository", "namespace", namespace)
			continue
		}
		defer os.RemoveAll(tmpDir)

		// Checkout base branch
		if err := gitCheckoutBranch(ctx, tmpDir, baseBranch, false); err != nil {
			logger.Error(err, "Failed to checkout base branch", "namespace", namespace)
			continue
		}

		// List all NetworkPolicy files for this namespace
		namespaceDir := filepath.Join("networkpolicies", clusterName, namespace)
		files, err := listFiles(tmpDir, namespaceDir)
		if err != nil {
			logger.Error(err, "Failed to list files", "namespace", namespace)
			continue
		}

		// Generate branch name
		branchName := generateBranchName(clusterName, namespace+"-removal")

		// Create branch
		if err := gitCheckoutBranch(ctx, tmpDir, branchName, true); err != nil {
			logger.Error(err, "Failed to create branch", "namespace", namespace)
			continue
		}

		// Delete all NetworkPolicy files for this namespace
		kustomizationPath := filepath.Join("networkpolicies", clusterName, "kustomization.yaml")
		for _, fileName := range files {
			filePath := filepath.Join(namespaceDir, fileName)
			if err := os.Remove(filepath.Join(tmpDir, filePath)); err != nil {
				logger.Error(err, "Failed to delete file", "filePath", filePath)
				// Continue with other files
			}

			// Update kustomization
			relPath, _ := filepath.Rel(filepath.Dir(kustomizationPath), filePath)
			if err := updateKustomizationResourcesSimple(r, ctx, tmpDir, kustomizationPath, relPath, false); err != nil {
				logger.Error(err, "Failed to update kustomization", "resource", relPath)
				// Continue - not critical
			}
		}

		// Commit and push
		commitMessage := fmt.Sprintf("NetworkPolicy: Remove namespace %s", namespace)
		if err := gitCommitAndPush(ctx, tmpDir, branchName, commitMessage, credentials, tlsVerify); err != nil {
			logger.Error(err, "Failed to commit and push", "namespace", namespace)
			continue
		}

		// Create PR
		provider, err := detectGitProvider(gitRepo.URL, gitRepo.Provider)
		if err != nil {
			logger.Error(err, "Failed to detect provider", "namespace", namespace)
			continue
		}

		apiBaseURL := getAPIBaseURL(provider, gitRepo.APIBaseURL, gitRepo.URL)
		prTitle := fmt.Sprintf("NetworkPolicy: Remove namespace %s", namespace)
		prDescription := fmt.Sprintf("Cluster: %s\nNamespace: %s (removed from whitelist)\nVariant: removal\nOperator: permission-binder-operator", clusterName, namespace)

		pr, err := createPullRequest(ctx, provider, apiBaseURL, gitRepo.URL, branchName, baseBranch, prTitle, prDescription, nil, credentials, tlsVerify)
		if err != nil {
			// Sanitize error and URLs to prevent token leakage
			sanitizedErr := sanitizeError(err, credentials)
			sanitizedRepoURL := sanitizeString(gitRepo.URL, credentials)
			sanitizedAPIBaseURL := sanitizeString(apiBaseURL, credentials)
			logger.Error(sanitizedErr, "Failed to create removal PR",
				"namespace", namespace,
				"branch", branchName,
				"provider", provider,
				"apiBaseURL", sanitizedAPIBaseURL,
				"repoURL", sanitizedRepoURL)
			os.RemoveAll(tmpDir)
			continue
		}

		// Update status
		if err := updateNetworkPolicyStatusWithPR(r, ctx, permissionBinder, namespace, pr.Number, branchName, pr.URL, "pr-removal"); err != nil {
			logger.Error(err, "Failed to update status", "namespace", namespace)
		}

		logger.Info("Created removal PR for namespace",
			"namespace", namespace,
			"prNumber", pr.Number,
			"prURL", pr.URL)
	}

	return nil
}

