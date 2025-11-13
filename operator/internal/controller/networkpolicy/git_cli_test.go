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
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestGetAskPassHelperPath tests the binary helper path resolution
func TestGetAskPassHelperPath(t *testing.T) {
	tests := []struct {
		name     string
		setup    func() (cleanup func())
		expected string
	}{
		{
			name: "default path when binary not found",
			setup: func() (cleanup func()) {
				// No setup needed, just return default path
				return func() {}
			},
			expected: "/usr/local/bin/git-askpass-helper",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cleanup := tt.setup()
			defer cleanup()

			path := getAskPassHelperPath()
			assert.Equal(t, tt.expected, path)
		})
	}
}

// TestWithGitCredentials tests environment variable setup for Git operations
func TestWithGitCredentials(t *testing.T) {
	tests := []struct {
		name             string
		baseEnv          []string
		credentials      *gitCredentials
		askpassHelper    string
		wantContains     []string
		wantNotContains  []string
	}{
		{
			name:    "adds credentials to environment",
			baseEnv: []string{"PATH=/usr/bin", "HOME=/home/user"},
			credentials: &gitCredentials{
				username: "testuser",
				token:    "testtoken",
				email:    "test@example.com",
			},
			askpassHelper: "/usr/local/bin/git-askpass-helper",
			wantContains: []string{
				"GIT_HTTP_USER=testuser",
				"GIT_HTTP_PASSWORD=testtoken",
				"GIT_ASKPASS=/usr/local/bin/git-askpass-helper",
				"GIT_TERMINAL_PROMPT=0",
				"PATH=/usr/bin",
				"HOME=/home/user",
			},
			wantNotContains: []string{},
		},
		{
			name:    "handles empty base environment",
			baseEnv: []string{},
			credentials: &gitCredentials{
				username: "user",
				token:    "token",
				email:    "user@test.com",
			},
			askpassHelper: "/path/to/helper",
			wantContains: []string{
				"GIT_HTTP_USER=user",
				"GIT_HTTP_PASSWORD=token",
				"GIT_ASKPASS=/path/to/helper",
				"GIT_TERMINAL_PROMPT=0",
			},
			wantNotContains: []string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			env := withGitCredentials(tt.baseEnv, tt.credentials, tt.askpassHelper)

			// Check all base env vars are preserved
			for _, want := range tt.baseEnv {
				assert.Contains(t, env, want, "base env var should be preserved")
			}

			// Check required vars are added
			for _, want := range tt.wantContains {
				assert.Contains(t, env, want, "required env var not found")
			}

			// Check unwanted vars are not present
			for _, notWant := range tt.wantNotContains {
				assert.NotContains(t, env, notWant, "unwanted env var found")
			}

			// Verify no credentials in PATH or other vars (security check)
			for _, envVar := range env {
				if strings.HasPrefix(envVar, "GIT_HTTP_USER=") ||
					strings.HasPrefix(envVar, "GIT_HTTP_PASSWORD=") ||
					strings.HasPrefix(envVar, "GIT_ASKPASS=") ||
					strings.HasPrefix(envVar, "GIT_TERMINAL_PROMPT=") {
					continue
				}
				assert.NotContains(t, envVar, tt.credentials.token, "token should not leak to other env vars")
				assert.NotContains(t, envVar, tt.credentials.username, "username should not leak to other env vars")
			}
		})
	}
}

// TestCloneGitRepo_ErrorHandling tests error scenarios for Git clone
// Note: Real Git operations require actual Git installation and network
// These tests focus on error handling logic
func TestCloneGitRepo_ErrorHandling(t *testing.T) {
	// Skip if not in CI environment or if Git is not available
	if testing.Short() {
		t.Skip("Skipping Git integration test in short mode")
	}

	ctx := context.Background()

	tests := []struct {
		name        string
		repoURL     string
		credentials *gitCredentials
		wantErr     bool
		errContains string
	}{
		{
			name:    "invalid URL format",
			repoURL: "not-a-valid-url",
			credentials: &gitCredentials{
				username: "test",
				token:    "test",
				email:    "test@test.com",
			},
			wantErr:     true,
			errContains: "failed to clone repository",
		},
		{
			name:    "empty URL",
			repoURL: "",
			credentials: &gitCredentials{
				username: "test",
				token:    "test",
				email:    "test@test.com",
			},
			wantErr:     true,
			errContains: "failed to clone repository",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tmpDir, err := cloneGitRepo(ctx, tt.repoURL, tt.credentials)

			if tt.wantErr {
				assert.Error(t, err)
				if tt.errContains != "" {
					assert.Contains(t, err.Error(), tt.errContains)
				}
				// Verify no temp dir was left behind
				if tmpDir != "" {
					_, statErr := os.Stat(tmpDir)
					assert.True(t, os.IsNotExist(statErr), "temp dir should be cleaned up on error")
				}
			} else {
				require.NoError(t, err)
				assert.NotEmpty(t, tmpDir)
				// Cleanup
				if tmpDir != "" {
					os.RemoveAll(tmpDir)
				}
			}
		})
	}
}

// TestGitCheckoutBranch_ErrorHandling tests branch checkout error scenarios
func TestGitCheckoutBranch_ErrorHandling(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping Git integration test in short mode")
	}

	ctx := context.Background()

	tests := []struct {
		name        string
		setupRepo   func(t *testing.T) string // Returns repo path
		branchName  string
		wantErr     bool
		errContains string
	}{
		{
			name: "invalid repository directory",
			setupRepo: func(t *testing.T) string {
				// Return non-existent directory
				return "/tmp/non-existent-git-repo-12345"
			},
			branchName:  "test-branch",
			wantErr:     true,
			errContains: "failed to check current branch",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repoDir := tt.setupRepo(t)
			defer func() {
				if strings.HasPrefix(repoDir, os.TempDir()) {
					os.RemoveAll(repoDir)
				}
			}()

			err := gitCheckoutBranch(ctx, repoDir, tt.branchName, true)

			if tt.wantErr {
				assert.Error(t, err)
				if tt.errContains != "" {
					assert.Contains(t, err.Error(), tt.errContains)
				}
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

// TestGitCommitAndPush_NoChanges tests idempotent behavior when no changes exist
func TestGitCommitAndPush_NoChanges(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping Git integration test in short mode")
	}

	ctx := context.Background()

	// Create a temporary Git repository
	tmpDir, err := os.MkdirTemp("", "git-test-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	// Initialize Git repo
	cmd := exec.CommandContext(ctx, "git", "init")
	cmd.Dir = tmpDir
	require.NoError(t, cmd.Run())

	// Configure Git user
	cmd = exec.CommandContext(ctx, "git", "config", "user.name", "Test User")
	cmd.Dir = tmpDir
	require.NoError(t, cmd.Run())

	cmd = exec.CommandContext(ctx, "git", "config", "user.email", "test@example.com")
	cmd.Dir = tmpDir
	require.NoError(t, cmd.Run())

	// Create an initial commit
	testFile := filepath.Join(tmpDir, "test.txt")
	require.NoError(t, os.WriteFile(testFile, []byte("initial content"), 0644))

	cmd = exec.CommandContext(ctx, "git", "add", "test.txt")
	cmd.Dir = tmpDir
	require.NoError(t, cmd.Run())

	cmd = exec.CommandContext(ctx, "git", "commit", "-m", "Initial commit")
	cmd.Dir = tmpDir
	require.NoError(t, cmd.Run())

	credentials := &gitCredentials{
		username: "test",
		token:    "test",
		email:    "test@example.com",
	}

	// Call gitCommitAndPush with no changes
	err = gitCommitAndPush(ctx, tmpDir, "main", "No changes commit", credentials)

	// Should return nil (no error) but also not create a commit
	assert.NoError(t, err, "should not error on no changes")

	// Verify no new commit was created
	cmd = exec.CommandContext(ctx, "git", "log", "--oneline")
	cmd.Dir = tmpDir
	output, err := cmd.Output()
	require.NoError(t, err)

	commits := strings.Split(strings.TrimSpace(string(output)), "\n")
	assert.Equal(t, 1, len(commits), "should still have only 1 commit")
}

// TestGitCommitAndPush_ErrorHandling tests error scenarios for commit/push operations
func TestGitCommitAndPush_ErrorHandling(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping Git integration test in short mode")
	}

	ctx := context.Background()

	tests := []struct {
		name        string
		setupRepo   func(t *testing.T) string
		branchName  string
		message     string
		credentials *gitCredentials
		wantErr     bool
		errContains string
	}{
		{
			name: "invalid repository directory",
			setupRepo: func(t *testing.T) string {
				return "/tmp/non-existent-git-repo-67890"
			},
			branchName: "test",
			message:    "test commit",
			credentials: &gitCredentials{
				username: "test",
				token:    "test",
				email:    "test@test.com",
			},
			wantErr:     true,
			errContains: "failed to set git user.name",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repoDir := tt.setupRepo(t)
			defer func() {
				if strings.HasPrefix(repoDir, os.TempDir()) {
					os.RemoveAll(repoDir)
				}
			}()

			err := gitCommitAndPush(ctx, repoDir, tt.branchName, tt.message, tt.credentials)

			if tt.wantErr {
				assert.Error(t, err)
				if tt.errContains != "" {
					assert.Contains(t, err.Error(), tt.errContains)
				}
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

// TestGitCredentials_Security tests that credentials are not leaked
func TestGitCredentials_Security(t *testing.T) {
	ctx := context.Background()

	credentials := &gitCredentials{
		username: "secret-user",
		token:    "super-secret-token-12345",
		email:    "secret@example.com",
	}

	// Test withGitCredentials doesn't leak secrets
	env := withGitCredentials([]string{"PATH=/usr/bin"}, credentials, "/path/to/helper")

	// Verify credentials are only in designated env vars
	for _, envVar := range env {
		if strings.HasPrefix(envVar, "GIT_HTTP_USER=") ||
			strings.HasPrefix(envVar, "GIT_HTTP_PASSWORD=") {
			continue // These are expected to contain credentials
		}
		assert.NotContains(t, envVar, credentials.token, "token should not leak to unrelated env vars")
	}

	// Test that error messages don't contain credentials
	// Simulate a failed clone with invalid URL
	_, err := cloneGitRepo(ctx, "invalid-url", credentials)
	require.Error(t, err)

	errMsg := err.Error()
	assert.NotContains(t, errMsg, credentials.token, "error message should not contain token")
	assert.NotContains(t, errMsg, credentials.username, "error message should not contain username")
}

// Benchmark tests for performance monitoring
func BenchmarkWithGitCredentials(b *testing.B) {
	baseEnv := make([]string, 10)
	for i := 0; i < 10; i++ {
		baseEnv[i] = fmt.Sprintf("VAR%d=value%d", i, i)
	}

	creds := &gitCredentials{
		username: "user",
		token:    "token",
		email:    "user@test.com",
	}

	helper := "/usr/local/bin/git-askpass-helper"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = withGitCredentials(baseEnv, creds, helper)
	}
}

// TestGitOperations_Integration is a comprehensive integration test
// This test requires:
// - Git installed
// - Network access (or use local test repo)
// - GitHub credentials (or mock server)
func TestGitOperations_Integration(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	// This is a placeholder for full integration test
	// In real implementation, this would:
	// 1. Clone a test repository
	// 2. Create a branch
	// 3. Make changes
	// 4. Commit and push
	// 5. Verify results
	// 6. Cleanup

	t.Skip("Full integration test not implemented - requires test repository setup")
}

