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
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ============================================================================
// Pure Functions Tests
// ============================================================================

func TestGetAPIBaseURL(t *testing.T) {
	tests := []struct {
		name           string
		provider       string
		customAPIBaseURL string
		repoURL        string
		expected       string
	}{
		{
			name:           "Custom API base URL takes precedence",
			provider:       "github",
			customAPIBaseURL: "https://custom.github.com/api/v3",
			repoURL:        "https://github.com/owner/repo",
			expected:       "https://custom.github.com/api/v3",
		},
		{
			name:           "GitHub default",
			provider:       "github",
			customAPIBaseURL: "",
			repoURL:        "https://github.com/owner/repo",
			expected:       "https://api.github.com",
		},
		{
			name:           "GitLab default",
			provider:       "gitlab",
			customAPIBaseURL: "",
			repoURL:        "https://gitlab.com/owner/repo",
			expected:       "https://gitlab.com/api/v4",
		},
		{
			name:           "Bitbucket default",
			provider:       "bitbucket",
			customAPIBaseURL: "",
			repoURL:        "https://bitbucket.org/workspace/repo",
			expected:       "https://api.bitbucket.org/2.0",
		},
		{
			name:           "Self-hosted GitHub (uses default when no custom URL)",
			provider:       "github",
			customAPIBaseURL: "",
			repoURL:        "https://git.example.com/owner/repo",
			expected:       "https://api.github.com", // Uses default, not self-hosted detection
		},
		{
			name:           "Self-hosted GitLab (uses default when no custom URL)",
			provider:       "gitlab",
			customAPIBaseURL: "",
			repoURL:        "https://gitlab.example.com/owner/repo",
			expected:       "https://gitlab.com/api/v4", // Uses default, not self-hosted detection
		},
		{
			name:           "Self-hosted Bitbucket (uses default when no custom URL)",
			provider:       "bitbucket",
			customAPIBaseURL: "",
			repoURL:        "https://bitbucket.example.com/workspace/repo",
			expected:       "https://api.bitbucket.org/2.0", // Uses default, not self-hosted detection
		},
		{
			name:           "Unknown provider with self-hosted",
			provider:       "unknown",
			customAPIBaseURL: "",
			repoURL:        "https://git.example.com/owner/repo",
			expected:       "https://git.example.com",
		},
		{
			name:           "Invalid repo URL (falls back to default)",
			provider:       "github",
			customAPIBaseURL: "",
			repoURL:        "://invalid-url",
			expected:       "https://api.github.com", // Invalid URL doesn't trigger self-hosted path, uses default
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := getAPIBaseURL(tt.provider, tt.customAPIBaseURL, tt.repoURL)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestExtractWorkspaceFromURL(t *testing.T) {
	tests := []struct {
		name        string
		repoURL     string
		expected    string
		expectError bool
	}{
		{
			name:        "Bitbucket standard URL",
			repoURL:     "https://bitbucket.org/workspace/repo.git",
			expected:    "workspace",
			expectError: false,
		},
		{
			name:        "Bitbucket URL without .git",
			repoURL:     "https://bitbucket.org/my-workspace/my-repo",
			expected:    "my-workspace",
			expectError: false,
		},
		{
			name:        "Self-hosted Bitbucket",
			repoURL:     "https://bitbucket.example.com/team/project",
			expected:    "team",
			expectError: false,
		},
		{
			name:        "URL with trailing slash",
			repoURL:     "https://bitbucket.org/workspace/repo/",
			expected:    "workspace",
			expectError: false,
		},
		{
			name:        "Invalid URL",
			repoURL:     "://invalid-url",
			expected:    "",
			expectError: true,
		},
		{
			name:        "URL without path (empty path returns empty string, no error)",
			repoURL:     "https://bitbucket.org",
			expected:    "", // Empty path returns empty string
			expectError: false, // Function doesn't return error for empty path
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := extractWorkspaceFromURL(tt.repoURL)
			if tt.expectError {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
				assert.Equal(t, tt.expected, result)
			}
		})
	}
}

func TestExtractRepositoryFromURL(t *testing.T) {
	tests := []struct {
		name     string
		repoURL  string
		expected string
	}{
		{
			name:     "Bitbucket standard URL with .git",
			repoURL:  "https://bitbucket.org/workspace/repo.git",
			expected: "repo",
		},
		{
			name:     "Bitbucket URL without .git",
			repoURL:  "https://bitbucket.org/workspace/my-repo",
			expected: "my-repo",
		},
		{
			name:     "GitHub URL",
			repoURL:  "https://github.com/owner/repo.git",
			expected: "repo",
		},
		{
			name:     "GitLab URL",
			repoURL:  "https://gitlab.com/group/project.git",
			expected: "project",
		},
		{
			name:     "Self-hosted with .git",
			repoURL:  "https://git.example.com/owner/repo-name.git",
			expected: "repo-name",
		},
		{
			name:     "URL with trailing slash",
			repoURL:  "https://bitbucket.org/workspace/repo/",
			expected: "repo",
		},
		{
			name:     "Invalid URL",
			repoURL:  "://invalid-url",
			expected: "",
		},
		{
			name:     "URL without enough path parts",
			repoURL:  "https://bitbucket.org/workspace",
			expected: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractRepositoryFromURL(tt.repoURL)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestHandleRateLimitError(t *testing.T) {
	tests := []struct {
		name     string
		err      error
		expected bool
	}{
		{
			name:     "429 status code",
			err:      errors.New("API error: 429 - rate limit exceeded"),
			expected: true,
		},
		{
			name:     "Rate limit in error message",
			err:      errors.New("rate limit exceeded"),
			expected: true,
		},
		{
			name:     "Too many requests",
			err:      errors.New("too many requests"),
			expected: true,
		},
		{
			name:     "Case sensitive - RATE LIMIT (uppercase)",
			err:      errors.New("RATE LIMIT exceeded"),
			expected: false, // strings.Contains is case-sensitive, "rate limit" != "RATE LIMIT"
		},
		{
			name:     "Not a rate limit error",
			err:      errors.New("not found"),
			expected: false,
		},
		{
			name:     "Nil error",
			err:      nil,
			expected: false,
		},
		{
			name:     "Other HTTP error",
			err:      errors.New("API error: 500 - internal server error"),
			expected: false,
		},
		{
			name:     "429 in middle of message",
			err:      errors.New("request failed with status 429"),
			expected: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := handleRateLimitError(tt.err)
			assert.Equal(t, tt.expected, result)
		})
	}
}

