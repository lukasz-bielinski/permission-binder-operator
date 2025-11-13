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
	"net/url"
	neturl "net/url"
	"os"
	"os/exec"
	"strings"

	"sigs.k8s.io/controller-runtime/pkg/log"
)

// cloneGitRepo clones repository using git CLI.
// Returns temporary directory path with cloned repository.
func cloneGitRepo(ctx context.Context, repoURL string, credentials *gitCredentials) (string, error) {
	logger := log.FromContext(ctx)

	tmpDir, err := os.MkdirTemp("", "permission-binder-git-*")
	if err != nil {
		return "", fmt.Errorf("failed to create temp directory: %w", err)
	}

	u, err := neturl.Parse(repoURL)
	if err != nil {
		os.RemoveAll(tmpDir)
		return "", fmt.Errorf("failed to parse repo URL: %w", err)
	}
	u.User = neturl.UserPassword(credentials.username, credentials.token)
	authURL := u.String()

	logger.V(1).Info("Cloning Git repository", "url", repoURL, "tempDir", tmpDir)

	cmd := exec.CommandContext(ctx, "git", "clone", "--depth", "1", authURL, tmpDir)
	if output, err := cmd.CombinedOutput(); err != nil {
		os.RemoveAll(tmpDir)
		networkPolicyGitOperationsTotal.WithLabelValues("clone", "error").Inc()
		return "", fmt.Errorf("failed to clone repository: %w\noutput: %s", err, string(output))
	}

	networkPolicyGitOperationsTotal.WithLabelValues("clone", "success").Inc()
	return tmpDir, nil
}

// gitCheckoutBranch checks out or creates a branch using git CLI.
// If create is false, only checks out existing branch.
// If create is true, creates new branch if it doesn't exist.
func gitCheckoutBranch(ctx context.Context, repoDir string, branchName string, create bool) error {
	// Check current branch first
	cmd := exec.CommandContext(ctx, "git", "rev-parse", "--abbrev-ref", "HEAD")
	cmd.Dir = repoDir
	currentBranch, err := cmd.Output()
	if err == nil && strings.TrimSpace(string(currentBranch)) == branchName {
		// Already on the requested branch
		return nil
	}

	if create {
		// Try to create new branch
		cmd = exec.CommandContext(ctx, "git", "checkout", "-b", branchName)
		cmd.Dir = repoDir
		if _, err := cmd.CombinedOutput(); err != nil {
			// Branch might already exist, try to checkout existing branch
			cmd = exec.CommandContext(ctx, "git", "checkout", branchName)
			cmd.Dir = repoDir
			if output, err := cmd.CombinedOutput(); err != nil {
				return fmt.Errorf("failed to checkout branch: %w\noutput: %s", err, string(output))
			}
		}
	} else {
		// Only checkout existing branch
		cmd = exec.CommandContext(ctx, "git", "checkout", branchName)
		cmd.Dir = repoDir
		if output, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("failed to checkout branch: %w\noutput: %s", err, string(output))
		}
	}
	return nil
}

// gitCommitAndPush commits and pushes changes using git CLI.
// Configures git user, adds all changes, commits, and pushes to remote.
// Returns early if there are no changes to commit.
func gitCommitAndPush(ctx context.Context, repoDir string, branchName string, commitMessage string, credentials *gitCredentials) error {
	logger := log.FromContext(ctx)

	// Configure git user
	cmd := exec.CommandContext(ctx, "git", "config", "user.name", credentials.username)
	cmd.Dir = repoDir
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to set git user.name: %w", err)
	}

	cmd = exec.CommandContext(ctx, "git", "config", "user.email", credentials.email)
	cmd.Dir = repoDir
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to set git user.email: %w", err)
	}

	// Add all changes
	cmd = exec.CommandContext(ctx, "git", "add", "-A")
	cmd.Dir = repoDir
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to add changes: %w\noutput: %s", err, string(output))
	}

	// Check if there are changes
	cmd = exec.CommandContext(ctx, "git", "status", "--porcelain")
	cmd.Dir = repoDir
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to check status: %w", err)
	}

	if len(output) == 0 {
		logger.V(1).Info("No changes to commit")
		return nil
	}

	// Commit
	cmd = exec.CommandContext(ctx, "git", "commit", "-m", commitMessage)
	cmd.Dir = repoDir
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to commit: %w\noutput: %s", err, string(output))
	}

	// Push (prepare URL with credentials)
	cmd = exec.CommandContext(ctx, "git", "config", "--get", "remote.origin.url")
	cmd.Dir = repoDir
	remoteURL, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to get remote URL: %w", err)
	}

	u, err := url.Parse(strings.TrimSpace(string(remoteURL)))
	if err != nil {
		return fmt.Errorf("failed to parse remote URL: %w", err)
	}
	u.User = url.UserPassword(credentials.username, credentials.token)
	authURL := u.String()

	cmd = exec.CommandContext(ctx, "git", "remote", "set-url", "origin", authURL)
	cmd.Dir = repoDir
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to set remote URL: %w", err)
	}

	// Fetch remote branches to check if branch exists
	cmd = exec.CommandContext(ctx, "git", "fetch", "origin")
	cmd.Dir = repoDir
	if output, err := cmd.CombinedOutput(); err != nil {
		logger.V(1).Info("Failed to fetch remote branches, continuing anyway", "error", string(output))
	}

	// Check if branch exists on remote
	cmd = exec.CommandContext(ctx, "git", "ls-remote", "--heads", "origin", branchName)
	cmd.Dir = repoDir
	remoteBranchOutput, err := cmd.Output()
	remoteBranchExists := err == nil && len(remoteBranchOutput) > 0

	if remoteBranchExists {
		// Branch exists on remote - fetch and update local tracking branch
		logger.V(1).Info("Branch exists on remote, fetching and updating", "branch", branchName)
		
		// Fetch the specific branch to update local refs
		cmd = exec.CommandContext(ctx, "git", "fetch", "origin", branchName+":"+branchName)
		cmd.Dir = repoDir
		if output, err := cmd.CombinedOutput(); err != nil {
			logger.V(1).Info("Failed to fetch branch, will try force push", "error", string(output))
		}

		// Set upstream tracking
		cmd = exec.CommandContext(ctx, "git", "branch", "--set-upstream-to=origin/"+branchName, branchName)
		cmd.Dir = repoDir
		_ = cmd.Run() // Ignore error if already set

		// Try pull with rebase first
		cmd = exec.CommandContext(ctx, "git", "pull", "--rebase", "origin", branchName)
		cmd.Dir = repoDir
		if output, err := cmd.CombinedOutput(); err != nil {
			// Rebase failed - use force push (acceptable for operator-managed branches)
			logger.V(1).Info("Rebase failed, using force push", "error", string(output))
			cmd = exec.CommandContext(ctx, "git", "push", "--force", "origin", branchName)
			cmd.Dir = repoDir
			if output, err := cmd.CombinedOutput(); err != nil {
				networkPolicyGitOperationsTotal.WithLabelValues("push", "error").Inc()
				return fmt.Errorf("failed to push (force): %w\noutput: %s", err, string(output))
			}
		} else {
			// Rebase succeeded, normal push
			cmd = exec.CommandContext(ctx, "git", "push", "origin", branchName)
			cmd.Dir = repoDir
			if output, err := cmd.CombinedOutput(); err != nil {
				networkPolicyGitOperationsTotal.WithLabelValues("push", "error").Inc()
				return fmt.Errorf("failed to push: %w\noutput: %s", err, string(output))
			}
		}
	} else {
		// Branch doesn't exist on remote - normal push with upstream
		cmd = exec.CommandContext(ctx, "git", "push", "-u", "origin", branchName)
		cmd.Dir = repoDir
		if output, err := cmd.CombinedOutput(); err != nil {
			networkPolicyGitOperationsTotal.WithLabelValues("push", "error").Inc()
			return fmt.Errorf("failed to push: %w\noutput: %s", err, string(output))
		}
	}

	networkPolicyGitOperationsTotal.WithLabelValues("push", "success").Inc()
	logger.Info("Pushed changes to remote", "branch", branchName)
	return nil
}

