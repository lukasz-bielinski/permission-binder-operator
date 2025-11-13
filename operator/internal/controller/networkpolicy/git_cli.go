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
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/config"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
	githttp "github.com/go-git/go-git/v5/plumbing/transport/http"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

// cloneGitRepo clones repository using go-git library.
// Returns temporary directory path with cloned repository.
// SECURITY: Credentials are passed via BasicAuth, never exposed in URLs or logs.
// tlsVerify controls TLS certificate verification (false = skip verification, insecure).
func cloneGitRepo(ctx context.Context, repoURL string, credentials *gitCredentials, tlsVerify bool) (string, error) {
	logger := log.FromContext(ctx)

	tmpDir, err := os.MkdirTemp("", "permission-binder-git-*")
	if err != nil {
		return "", fmt.Errorf("failed to create temp directory: %w", err)
	}

	// Sanitize URL in logs (in case it contains credentials)
	sanitizedURL := sanitizeString(repoURL, credentials)
	logger.V(1).Info("Cloning Git repository", "url", sanitizedURL, "tempDir", tmpDir, "tlsVerify", tlsVerify)

	// Prepare authentication
	auth := &githttp.BasicAuth{
		Username: credentials.username,
		Password: credentials.token,
	}

	// Clone options
	cloneOptions := &git.CloneOptions{
		URL:             repoURL,
		Auth:            auth,
		Depth:           1, // Shallow clone
		SingleBranch:    false,
		Progress:        nil, // No progress output
		Tags:            git.NoTags,
		InsecureSkipTLS: !tlsVerify, // Skip TLS verification if tlsVerify is false
	}

	// Clone repository
	// Note: v5 uses bare as argument, v6 will use CloneOptions.Bare field
	_, err = git.PlainCloneContext(ctx, tmpDir, false, cloneOptions)
	if err != nil {
		os.RemoveAll(tmpDir)
		networkPolicyGitOperationsTotal.WithLabelValues("clone", "error").Inc()
		// Sanitize error to prevent token leakage
		return "", fmt.Errorf("failed to clone repository: %w", sanitizeError(err, credentials))
	}

	networkPolicyGitOperationsTotal.WithLabelValues("clone", "success").Inc()
	return tmpDir, nil
}

// gitCheckoutBranch checks out or creates a branch using go-git.
// If create is false, only checks out existing branch.
// If create is true, creates new branch if it doesn't exist, or checks out if it already exists.
func gitCheckoutBranch(ctx context.Context, repoDir string, branchName string, create bool) error {
	// Open repository
	repo, err := git.PlainOpen(repoDir)
	if err != nil {
		return fmt.Errorf("failed to open repository: %w", err)
	}

	// Get worktree
	worktree, err := repo.Worktree()
	if err != nil {
		return fmt.Errorf("failed to get worktree: %w", err)
	}

	// Check current branch
	head, err := repo.Head()
	if err == nil {
		currentBranch := head.Name().Short()
		if currentBranch == branchName {
			// Already on the requested branch
			return nil
		}
	}

	// Check if branch exists locally
	branchRef := plumbing.NewBranchReferenceName(branchName)
	_, err = repo.Reference(branchRef, false)
	branchExists := err == nil

	// If branch exists locally, just checkout (don't try to create)
	if branchExists {
		checkoutOptions := &git.CheckoutOptions{
			Branch: branchRef,
			Create: false, // Branch already exists
		}
		if err := worktree.Checkout(checkoutOptions); err != nil {
			return fmt.Errorf("failed to checkout existing branch: %w", err)
		}
		return nil
	}

	// Branch doesn't exist locally
	if !create {
		return fmt.Errorf("branch %s does not exist and create=false", branchName)
	}

	// Create new branch from HEAD
	headRef, err := repo.Head()
	if err != nil {
		return fmt.Errorf("failed to get HEAD: %w", err)
	}

	// Create branch reference
	newRef := plumbing.NewHashReference(branchRef, headRef.Hash())
	if err := repo.Storer.SetReference(newRef); err != nil {
		return fmt.Errorf("failed to create branch reference: %w", err)
	}

	// Checkout newly created branch
	checkoutOptions := &git.CheckoutOptions{
		Branch: branchRef,
		Create: false, // Already created above
	}

	if err := worktree.Checkout(checkoutOptions); err != nil {
		return fmt.Errorf("failed to checkout newly created branch: %w", err)
	}

	return nil
}

// gitCommitAndPush commits and pushes changes using go-git.
// Configures git user, adds all changes, commits, and pushes to remote.
// Returns early if there are no changes to commit.
// tlsVerify controls TLS certificate verification (false = skip verification, insecure).
func gitCommitAndPush(ctx context.Context, repoDir string, branchName string, commitMessage string, credentials *gitCredentials, tlsVerify bool) error {
	logger := log.FromContext(ctx)

	// Custom HTTP client will be used via auth if TLS verify is disabled

	// Open repository
	repo, err := git.PlainOpen(repoDir)
	if err != nil {
		return fmt.Errorf("failed to open repository: %w", err)
	}

	// Get worktree
	worktree, err := repo.Worktree()
	if err != nil {
		return fmt.Errorf("failed to get worktree: %w", err)
	}

	// Configure git user (stored in commit signature, not in git config)
	// go-git doesn't require git config for commits, we use signature directly

	// Add all changes
	if err := worktree.AddWithOptions(&git.AddOptions{All: true}); err != nil {
		return fmt.Errorf("failed to add changes: %w", err)
	}

	// Check if there are changes
	status, err := worktree.Status()
	if err != nil {
		return fmt.Errorf("failed to get status: %w", err)
	}

	if status.IsClean() {
		logger.V(1).Info("No changes to commit")
		return nil
	}

	// Commit
	commitOptions := &git.CommitOptions{
		Author: &object.Signature{
			Name:  credentials.username,
			Email: credentials.email,
			When:  time.Now(),
		},
	}

	_, err = worktree.Commit(commitMessage, commitOptions)
	if err != nil {
		return fmt.Errorf("failed to commit: %w", err)
	}

	// Get remote
	remote, err := repo.Remote("origin")
	if err != nil {
		return fmt.Errorf("failed to get remote: %w", err)
	}

	// Prepare authentication
	auth := &githttp.BasicAuth{
		Username: credentials.username,
		Password: credentials.token,
	}

	// Check if branch exists on remote
	branchRef := plumbing.NewBranchReferenceName(branchName)
	listOptions := &git.ListOptions{
		Auth:            auth,
		InsecureSkipTLS: !tlsVerify,
	}
	remoteRefs, err := remote.List(listOptions)
	if err != nil {
		// Sanitize error to prevent token leakage
		sanitizedErr := sanitizeError(err, credentials)
		logger.V(1).Info("Failed to list remote refs, continuing anyway", "error", sanitizedErr)
	}

	remoteBranchExists := false
	for _, ref := range remoteRefs {
		if ref.Name() == branchRef {
			remoteBranchExists = true
			break
		}
	}

	// Prepare push options
	pushOptions := &git.PushOptions{
		Auth:            auth,
		RemoteName:      "origin",
		InsecureSkipTLS: !tlsVerify,
		RefSpecs: []config.RefSpec{
			config.RefSpec(fmt.Sprintf("+refs/heads/%s:refs/heads/%s", branchName, branchName)),
		},
	}

	if remoteBranchExists {
		// Branch exists on remote - try to fetch and rebase first
		logger.V(1).Info("Branch exists on remote, fetching and updating", "branch", branchName)

		// Fetch latest changes
		fetchOptions := &git.FetchOptions{
			Auth:            auth,
			RemoteName:      "origin",
			InsecureSkipTLS: !tlsVerify,
			RefSpecs: []config.RefSpec{
				config.RefSpec(fmt.Sprintf("refs/heads/%s:refs/remotes/origin/%s", branchName, branchName)),
			},
		}

		if err := repo.Fetch(fetchOptions); err != nil && err != git.NoErrAlreadyUpToDate {
			// Sanitize error to prevent token leakage
			sanitizedErr := sanitizeError(err, credentials)
			logger.V(1).Info("Failed to fetch branch, will use force push", "error", sanitizedErr)
		} else {
			// Try to merge remote changes (simplified - just use force push for operator-managed branches)
			// For operator-managed branches, force push is acceptable
			logger.V(1).Info("Using force push for operator-managed branch")
		}

		// Use force push (acceptable for operator-managed branches)
		pushOptions.RefSpecs = []config.RefSpec{
			config.RefSpec(fmt.Sprintf("+refs/heads/%s:refs/heads/%s", branchName, branchName)),
		}
	} else {
		// Branch doesn't exist on remote - normal push with upstream
		pushOptions.RefSpecs = []config.RefSpec{
			config.RefSpec(fmt.Sprintf("refs/heads/%s:refs/heads/%s", branchName, branchName)),
		}
	}

	// Push
	if err := repo.PushContext(ctx, pushOptions); err != nil {
		networkPolicyGitOperationsTotal.WithLabelValues("push", "error").Inc()
		// Sanitize error to prevent token leakage
		return fmt.Errorf("failed to push: %w", sanitizeError(err, credentials))
	}

	networkPolicyGitOperationsTotal.WithLabelValues("push", "success").Inc()
	logger.Info("Pushed changes to remote", "branch", branchName)
	return nil
}
