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
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	networkingv1 "k8s.io/api/networking/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/yaml"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// ProcessNetworkPolicyForNamespace processes NetworkPolicy management for a single namespace.
//
// This function implements the core GitOps workflow:
//  1. Clones the Git repository
//  2. Processes templates from the template directory
//  3. Creates or updates NetworkPolicy files in Git
//  4. Optionally backs up existing NetworkPolicies
//  5. Commits changes and creates a Pull Request
//
// The function handles three variants:
//   - Variant A: Create NetworkPolicy from template (if not exists)
//   - Variant B: Backup existing template-based NetworkPolicy
//   - Variant C: Backup existing non-template NetworkPolicy
//
// Parameters:
//   - ctx: Context for cancellation and timeout
//   - r: ReconcilerInterface for Kubernetes API access
//   - permissionBinder: The PermissionBinder CR containing configuration
//   - namespace: The namespace to process
//
// Returns:
//   - error: Returns an error if any step fails, nil on success
//
// Example:
//
//	err := ProcessNetworkPolicyForNamespace(ctx, reconciler, binder, "my-namespace")
//	if err != nil {
//	    logger.Error(err, "Failed to process namespace")
//	}
func ProcessNetworkPolicyForNamespace(
	ctx context.Context,
	r ReconcilerInterface,
	permissionBinder *permissionv1.PermissionBinder,
	namespace string,
) error {
	logger := log.FromContext(ctx)

	gitRepo := permissionBinder.Spec.NetworkPolicy.GitRepository
	clusterName := gitRepo.ClusterName
	templateDir := permissionBinder.Spec.NetworkPolicy.TemplateDir
	baseBranch := gitRepo.BaseBranch
	backupExisting := permissionBinder.Spec.NetworkPolicy.BackupExisting

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

	// Clone repo (always fresh clone for self-contained test isolation)
	tmpDir, err := cloneGitRepo(ctx, gitRepo.URL, credentials, tlsVerify)
	if err != nil {
		return fmt.Errorf("failed to clone repository: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	// Fetch latest changes from upstream to ensure fresh state
	// This is critical for test isolation - always work with latest main branch
	cmd := exec.CommandContext(ctx, "git", "fetch", "origin", baseBranch)
	cmd.Dir = tmpDir
	if output, err := cmd.CombinedOutput(); err != nil {
		logger.V(1).Info("Failed to fetch latest changes (continuing anyway)", "error", string(output))
		// Continue - shallow clone might already have latest
	}

	// Checkout base branch (always fresh from upstream)
	if err := gitCheckoutBranch(ctx, tmpDir, baseBranch, false); err != nil {
		return fmt.Errorf("failed to checkout base branch: %w", err)
	}

	// Reset to origin/baseBranch to ensure we're on latest upstream state
	cmd = exec.CommandContext(ctx, "git", "reset", "--hard", fmt.Sprintf("origin/%s", baseBranch))
	cmd.Dir = tmpDir
	if output, err := cmd.CombinedOutput(); err != nil {
		logger.V(1).Info("Failed to reset to origin (continuing anyway)", "error", string(output))
		// Continue - might already be on correct commit
	}

	// Get all templates
	templates, err := listFiles(tmpDir, templateDir)
	if err != nil {
		// SAFE FEATURE: If template directory error, log and continue (don't fail)
		logger.Error(err, "Failed to get templates, skipping namespace",
			"namespace", namespace)
		return nil // Continue with other namespaces
	}

	// Get all NetworkPolicies from namespace
	var policyList networkingv1.NetworkPolicyList
	if err := r.List(ctx, &policyList, client.InNamespace(namespace)); err != nil {
		return fmt.Errorf("failed to get cluster policies: %w", err)
	}
	clusterPolicies := policyList.Items

	// Create a map of existing policies by name
	clusterPolicyMap := make(map[string]*networkingv1.NetworkPolicy)
	for i := range clusterPolicies {
		clusterPolicyMap[clusterPolicies[i].Name] = &clusterPolicies[i]
	}

	// Process templates (Variant A: new from template)
	var filesToCreate []struct {
		path    string
		content []byte
		policy  *networkingv1.NetworkPolicy
		isBackup bool // true if file is backed up from cluster (Variant B/C), false if created from template (Variant A)
	}

	for _, templateName := range templates {
		expectedPolicyName := getNetworkPolicyName(namespace, templateName)
		fileName := fmt.Sprintf("%s-%s.yaml", namespace, strings.TrimSuffix(templateName, ".yaml"))
		filePath := getNetworkPolicyFilePath(clusterName, namespace, fileName)

		// Check if file exists in Git
		if fileExists(tmpDir, filePath) {
			// File already exists in Git - skip
			continue
		}

		// Check if policy exists in cluster
		clusterPolicy, existsInCluster := clusterPolicyMap[expectedPolicyName]

		if !existsInCluster {
			// Variant A: Create from template (simple YAML text editing)
			yamlContent, err := processTemplate(r, ctx, tmpDir, templateDir, templateName, namespace, clusterName)
			if err != nil {
				logger.Error(err, "Failed to process template", "template", templateName)
				continue
			}

			// Parse policy for Variant A detection (check if all files are from templates)
			var policy networkingv1.NetworkPolicy
			if err := yaml.Unmarshal(yamlContent, &policy); err != nil {
				logger.Error(err, "Failed to parse modified template", "template", templateName)
				continue
			}

			filesToCreate = append(filesToCreate, struct {
				path    string
				content []byte
				policy  *networkingv1.NetworkPolicy
				isBackup bool
			}{
				path:    filePath,
				content: yamlContent,
				policy:  &policy,
				isBackup: false, // Variant A: created from template
			})
		} else if backupExisting && shouldBackupExistingPolicy(namespace, backupExisting, permissionBinder.Spec.NetworkPolicy.ExcludeBackupForNamespaces) {
			// Variant B: Backup existing template-based policy
			yamlContent, err := backupNetworkPolicy(r, ctx, namespace, expectedPolicyName)
			if err != nil {
				logger.Error(err, "Failed to backup policy", "policy", expectedPolicyName)
				continue
			}

			filesToCreate = append(filesToCreate, struct {
				path    string
				content []byte
				policy  *networkingv1.NetworkPolicy
				isBackup bool
			}{
				path:    filePath,
				content: yamlContent,
				policy:  clusterPolicy,
				isBackup: true, // Variant B: backup existing template-based policy
			})
		}
	}

	// Process other NetworkPolicies (Variant C: backup other policies)
	if backupExisting && shouldBackupExistingPolicy(namespace, backupExisting, permissionBinder.Spec.NetworkPolicy.ExcludeBackupForNamespaces) {
		for _, clusterPolicy := range clusterPolicies {
			// Check if this policy is from a template
			isFromTemplate := false
			for _, templateName := range templates {
				if isPolicyFromTemplate(clusterPolicy.Name, namespace, templateName) {
					isFromTemplate = true
					break
				}
			}

			if !isFromTemplate {
				// Variant C: Backup other policy
				fileName := fmt.Sprintf("%s.yaml", clusterPolicy.Name)
				filePath := getNetworkPolicyFilePath(clusterName, namespace, fileName)

				// Check if file exists in Git
				if !fileExists(tmpDir, filePath) {
					// Variant C: Backup other policy
					yamlContent, err := backupNetworkPolicy(r, ctx, namespace, clusterPolicy.Name)
					if err != nil {
						logger.Error(err, "Failed to backup policy", "policy", clusterPolicy.Name)
						continue
					}

					filesToCreate = append(filesToCreate, struct {
						path    string
						content []byte
						policy  *networkingv1.NetworkPolicy
						isBackup bool
					}{
						path:    filePath,
						content: yamlContent,
						policy:  &clusterPolicy,
						isBackup: true, // Variant C: backup other policy
					})
				}
			}
		}
	}

	// If no files to create, skip PR creation
	if len(filesToCreate) == 0 {
		logger.V(1).Info("No files to create for namespace", "namespace", namespace)
		return nil
	}

	// Generate branch name
	branchName := generateBranchName(clusterName, namespace)

	// Check if branch already exists and has no open PR
	provider, err := detectGitProvider(gitRepo.URL, gitRepo.Provider)
	if err != nil {
		return fmt.Errorf("failed to detect provider: %w", err)
	}

	apiBaseURL := getAPIBaseURL(provider, gitRepo.APIBaseURL, gitRepo.URL)
	existingPR, err := getPRByBranch(ctx, provider, apiBaseURL, gitRepo.URL, branchName, credentials)
	if err == nil && existingPR != nil && existingPR.State == "OPEN" {
		// PR already exists and is open - skip
		logger.V(1).Info("PR already exists and is open for namespace", "namespace", namespace, "prNumber", existingPR.Number)
		return nil
	}

	// Always delete branch on remote before creating new one (for test resilience)
	// This ensures clean state even if previous test cleanup failed
	logger.V(1).Info("Deleting branch on remote before creating new one", "branch", branchName, "namespace", namespace)
	deleteBranch(ctx, provider, apiBaseURL, gitRepo.URL, branchName, credentials)
	// Ignore errors - branch might not exist, which is fine

	// Create new branch
	if err := gitCheckoutBranch(ctx, tmpDir, branchName, true); err != nil {
		return fmt.Errorf("failed to create branch: %w", err)
	}

	// Write files to Git
	kustomizationPath := filepath.Join("networkpolicies", clusterName, "kustomization.yaml")
	if err := ensureKustomizationExistsSimple(r, ctx, tmpDir, kustomizationPath); err != nil {
		return fmt.Errorf("failed to ensure kustomization exists: %w", err)
	}

	for _, file := range filesToCreate {
		if err := writeFile(tmpDir, file.path, file.content); err != nil {
			return fmt.Errorf("failed to write file: %w", err)
		}

		// Update kustomization
		// Calculate relative path from kustomization.yaml directory to file
		relPath, _ := filepath.Rel(filepath.Dir(kustomizationPath), file.path)
		// updateKustomizationResourcesSimple expects relative path (already calculated above)
		if err := updateKustomizationResourcesSimple(r, ctx, tmpDir, kustomizationPath, relPath, true); err != nil {
			logger.Error(err, "Failed to update kustomization", "resource", relPath)
			// Continue - not critical
		}
	}

	// Determine variant for auto-merge
	variant := "new"
	autoMerge := false
	if len(filesToCreate) > 0 {
		// Check if any file is a backup (Variant B or C)
		hasBackup := false
		for _, file := range filesToCreate {
			if file.isBackup {
				hasBackup = true
				break
			}
		}

		if hasBackup {
			// Variant B or C: backup existing policy
			variant = "backup"
			autoMerge = false // Backup always requires manual approval
		} else {
			// Variant A: all files created from templates
			variant = "new"
			autoMerge = permissionBinder.Spec.NetworkPolicy.AutoMerge != nil && permissionBinder.Spec.NetworkPolicy.AutoMerge.Enabled
		}
	}

	// Create commit message
	commitMessage := fmt.Sprintf("NetworkPolicy: %s for namespace %s", variant, namespace)

	// Commit and push
	if err := gitCommitAndPush(ctx, tmpDir, branchName, commitMessage, credentials, tlsVerify); err != nil {
		return fmt.Errorf("failed to commit and push: %w", err)
	}

	// Create PR
	prTitle := fmt.Sprintf("NetworkPolicy: %s for namespace %s", variant, namespace)
	prDescription := fmt.Sprintf("Cluster: %s\nNamespace: %s\nVariant: %s\nOperator: permission-binder-operator", clusterName, namespace, variant)

	var labels []string
	if autoMerge && permissionBinder.Spec.NetworkPolicy.AutoMerge != nil {
		labels = append(labels, permissionBinder.Spec.NetworkPolicy.AutoMerge.Label)
	}

	pr, err := createPullRequest(ctx, provider, apiBaseURL, gitRepo.URL, branchName, baseBranch, prTitle, prDescription, labels, credentials)
	if err != nil {
		// Handle rate limit
		if handleRateLimitError(err) {
			logger.Error(err, "Rate limit exceeded for PR creation",
				"namespace", namespace,
				"severity", "error",
				"security_impact", "medium",
				"action", "networkpolicy_rate_limit_exceeded")
			NetworkPolicyPRCreationErrorsTotal.WithLabelValues(clusterName, namespace, variant, "rate_limit").Inc()
		}
		return fmt.Errorf("failed to create PR: %w", err)
	}

	// Auto-merge PR if enabled
	if autoMerge && permissionBinder.Spec.NetworkPolicy.AutoMerge != nil && permissionBinder.Spec.NetworkPolicy.AutoMerge.Enabled {
		// Wait a bit for PR to be ready (GitHub needs time to process)
		time.Sleep(2 * time.Second)

		// Try to merge PR
		if err := mergePullRequest(ctx, provider, apiBaseURL, gitRepo.URL, pr.Number, credentials); err != nil {
			logger.Error(err, "Failed to auto-merge PR", "prNumber", pr.Number)
			// Continue - PR is still created, just not merged
		} else {
			logger.Info("Auto-merged NetworkPolicy PR", "prNumber", pr.Number, "prURL", pr.URL)
		}
	}

	// Update status
	state := "pr-created"
	if autoMerge {
		// Check if PR was actually merged
		time.Sleep(1 * time.Second)
		updatedPR, err := getPRByBranch(ctx, provider, apiBaseURL, gitRepo.URL, branchName, credentials)
		if err == nil && updatedPR != nil && updatedPR.State == "MERGED" {
			state = "pr-merged"
		} else {
			state = "pr-pending" // Auto-merge might be waiting for checks
		}
	} else {
		state = "pr-pending"
	}

	if err := updateNetworkPolicyStatusWithPR(r, ctx, permissionBinder, namespace, pr.Number, branchName, pr.URL, state); err != nil {
		logger.Error(err, "Failed to update status", "namespace", namespace)
	}

	// Increment metrics
	NetworkPolicyPRsCreatedTotal.WithLabelValues(clusterName, namespace, variant).Inc()

	logger.Info("Created NetworkPolicy PR",
		"namespace", namespace,
		"variant", variant,
		"prNumber", pr.Number,
		"prURL", pr.URL,
		"autoMerge", autoMerge,
		"state", state)

	return nil
}

