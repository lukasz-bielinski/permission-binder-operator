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
	"os"
	"os/exec"
	"strings"

	"sigs.k8s.io/controller-runtime/pkg/log"
)

// cloneGitRepo clones repository using git CLI.
// Returns temporary directory path with cloned repository.
// SECURITY: Uses GIT_ASKPASS to avoid exposing token in process arguments/logs.
// tlsVerify controls TLS certificate verification (false = skip verification, insecure).
func cloneGitRepo(ctx context.Context, repoURL string, credentials *gitCredentials, tlsVerify bool) (string, error) {
	logger := log.FromContext(ctx)

	tmpDir, err := os.MkdirTemp("", "permission-binder-git-*")
	if err != nil {
		return "", fmt.Errorf("failed to create temp directory: %w", err)
	}

	// Use binary askpass helper (compiled into Docker image, distroless-compatible)
	// This prevents token from appearing in process arguments or logs
	askpassHelper := getAskPassHelperPath()

	// Use original URL without credentials - git will use askpass helper
	logger.V(1).Info("Cloning Git repository", "url", repoURL, "tempDir", tmpDir, "tlsVerify", tlsVerify)

	cmd := exec.CommandContext(ctx, "git", "clone", "--depth", "1", repoURL, tmpDir)
	cmd.Env = withGitCredentials(os.Environ(), credentials, askpassHelper, tlsVerify)
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
// tlsVerify controls TLS certificate verification (false = skip verification, insecure).
func gitCommitAndPush(ctx context.Context, repoDir string, branchName string, commitMessage string, credentials *gitCredentials, tlsVerify bool) error {
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

	// Get original remote URL (without credentials)
	cmd = exec.CommandContext(ctx, "git", "config", "--get", "remote.origin.url")
	cmd.Dir = repoDir
	remoteURL, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to get remote URL: %w", err)
	}

	// Parse URL and remove any existing credentials
	u, err := url.Parse(strings.TrimSpace(string(remoteURL)))
	if err != nil {
		return fmt.Errorf("failed to parse remote URL: %w", err)
	}
	// Remove credentials from URL if present
	u.User = nil
	cleanURL := u.String()

	// Set remote URL without credentials - git will use askpass helper
	cmd = exec.CommandContext(ctx, "git", "remote", "set-url", "origin", cleanURL)
	cmd.Dir = repoDir
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to set remote URL: %w", err)
	}

	// Use binary askpass helper (compiled into Docker image, distroless-compatible)
	askpassHelper := getAskPassHelperPath()

	// Prepare environment with credentials for all git operations
	env := withGitCredentials(os.Environ(), credentials, askpassHelper, tlsVerify)

	// Fetch remote branches to check if branch exists
	cmd = exec.CommandContext(ctx, "git", "fetch", "origin")
	cmd.Dir = repoDir
	cmd.Env = env
	if output, err := cmd.CombinedOutput(); err != nil {
		logger.V(1).Info("Failed to fetch remote branches, continuing anyway", "error", string(output))
	}

	// Check if branch exists on remote
	cmd = exec.CommandContext(ctx, "git", "ls-remote", "--heads", "origin", branchName)
	cmd.Dir = repoDir
	cmd.Env = env
	remoteBranchOutput, err := cmd.Output()
	remoteBranchExists := err == nil && len(remoteBranchOutput) > 0

	if remoteBranchExists {
		// Branch exists on remote - fetch and update local tracking branch
		logger.V(1).Info("Branch exists on remote, fetching and updating", "branch", branchName)
		
		// Fetch the specific branch to update local refs
		cmd = exec.CommandContext(ctx, "git", "fetch", "origin", branchName+":"+branchName)
		cmd.Dir = repoDir
		cmd.Env = env
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
		cmd.Env = env
		if output, err := cmd.CombinedOutput(); err != nil {
			// Rebase failed - use force push (acceptable for operator-managed branches)
			logger.V(1).Info("Rebase failed, using force push", "error", string(output))
			cmd = exec.CommandContext(ctx, "git", "push", "--force", "origin", branchName)
			cmd.Dir = repoDir
			cmd.Env = env
			if output, err := cmd.CombinedOutput(); err != nil {
				networkPolicyGitOperationsTotal.WithLabelValues("push", "error").Inc()
				return fmt.Errorf("failed to push (force): %w\noutput: %s", err, string(output))
			}
		} else {
			// Rebase succeeded, normal push
			cmd = exec.CommandContext(ctx, "git", "push", "origin", branchName)
			cmd.Dir = repoDir
			cmd.Env = env
			if output, err := cmd.CombinedOutput(); err != nil {
				networkPolicyGitOperationsTotal.WithLabelValues("push", "error").Inc()
				return fmt.Errorf("failed to push: %w\noutput: %s", err, string(output))
			}
		}
	} else {
		// Branch doesn't exist on remote - normal push with upstream
		cmd = exec.CommandContext(ctx, "git", "push", "-u", "origin", branchName)
		cmd.Dir = repoDir
		cmd.Env = env
		if output, err := cmd.CombinedOutput(); err != nil {
			networkPolicyGitOperationsTotal.WithLabelValues("push", "error").Inc()
			return fmt.Errorf("failed to push: %w\noutput: %s", err, string(output))
		}
	}

	networkPolicyGitOperationsTotal.WithLabelValues("push", "success").Inc()
	logger.Info("Pushed changes to remote", "branch", branchName)
	return nil
}

// getAskPassHelperPath returns the path to the git-askpass-helper binary.
// The helper is compiled into the Docker image and available at /usr/local/bin/git-askpass-helper.
// This binary reads credentials from environment variables, preventing tokens from appearing
// in process arguments, logs, or file contents.
func getAskPassHelperPath() string {
	// Check if helper exists at standard location (in Docker image)
	helperPath := "/usr/local/bin/git-askpass-helper"
	if _, err := os.Stat(helperPath); err == nil {
		return helperPath
	}
	
	// Fallback: try to find it in PATH (for local development)
	if path, err := exec.LookPath("git-askpass-helper"); err == nil {
		return path
	}
	
	// Default to standard location (will fail at runtime if not found, which is expected)
	return helperPath
}

// withGitCredentials prepares environment variables for git commands to use askpass helper.
// This ensures tokens never appear in process arguments, logs, or file contents.
// The askpassHelperPath should point to the compiled git-askpass-helper binary.
// tlsVerify controls TLS certificate verification (false = skip verification, insecure).
func withGitCredentials(baseEnv []string, credentials *gitCredentials, askpassHelperPath string, tlsVerify bool) []string {
	env := make([]string, 0, len(baseEnv)+6)
	env = append(env, baseEnv...)
	
	// Set credentials in environment variables (binary helper reads from these)
	env = append(env, "GIT_HTTP_USER="+credentials.username)
	env = append(env, "GIT_HTTP_PASSWORD="+credentials.token)
	
	// Set GIT_ASKPASS to use our binary helper (distroless-compatible)
	env = append(env, "GIT_ASKPASS="+askpassHelperPath)
	// Disable terminal prompts
	env = append(env, "GIT_TERMINAL_PROMPT=0")
	
	// Configure TLS verification (similar to LDAP ldapTlsVerify)
	if !tlsVerify {
		env = append(env, "GIT_SSL_NO_VERIFY=true")
	}
	
	return env
}

