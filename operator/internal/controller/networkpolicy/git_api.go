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
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"strings"
	"time"
)

// gitAPIRequest makes HTTP request to Git provider API.
// Handles JSON marshaling, request creation, and response parsing.
// Returns error if status code is not 2xx.
// tlsVerify controls TLS certificate verification (false = skip verification, insecure).
func gitAPIRequest(ctx context.Context, method, endpoint string, payload interface{}, headers map[string]string, tlsVerify bool) ([]byte, error) {
	var body io.Reader
	if payload != nil {
		jsonData, err := json.Marshal(payload)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal payload: %w", err)
		}
		body = strings.NewReader(string(jsonData))
	}

	req, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	// Configure HTTP client with TLS verification setting
	transport := &http.Transport{}
	if !tlsVerify {
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	}
	client := &http.Client{
		Timeout:   30 * time.Second,
		Transport: transport,
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to execute request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// Sanitize response body to prevent token leakage
		sanitizedBody := sanitizeString(string(respBody), nil)
		return nil, fmt.Errorf("API error: %d - %s", resp.StatusCode, sanitizedBody)
	}

	return respBody, nil
}

// createPullRequest creates a PR using Git provider API.
// Supports GitHub, GitLab, and Bitbucket with provider-specific API formats.
// tlsVerify controls TLS certificate verification (false = skip verification, insecure).
func createPullRequest(ctx context.Context, provider, apiBaseURL, repoURL, branchName, baseBranch, title, description string, labels []string, credentials *gitCredentials, tlsVerify bool) (*pullRequest, error) {
	var endpoint string
	var payload map[string]interface{}
	var headers map[string]string

	u, err := neturl.Parse(repoURL)
	if err != nil {
		return nil, fmt.Errorf("failed to parse repo URL: %w", err)
	}

	switch provider {
	case "github":
		parts := strings.Split(strings.Trim(u.Path, "/"), "/")
		if len(parts) < 2 {
			return nil, fmt.Errorf("invalid GitHub repo URL: %s", repoURL)
		}
		endpoint = fmt.Sprintf("%s/repos/%s/%s/pulls", apiBaseURL, parts[0], strings.TrimSuffix(parts[1], ".git"))
		payload = map[string]interface{}{
			"title": title,
			"head":  branchName,
			"base":  baseBranch,
			"body":  description,
		}
		if len(labels) > 0 {
			payload["labels"] = labels
		}
		headers = map[string]string{
			"Authorization": "token " + credentials.token,
			"Content-Type":  "application/json",
			"Accept":        "application/vnd.github.v3+json",
		}

	case "gitlab":
		projectPath := strings.TrimSuffix(strings.TrimPrefix(u.Path, "/"), ".git")
		projectPath = neturl.PathEscape(projectPath)
		endpoint = fmt.Sprintf("%s/projects/%s/merge_requests", apiBaseURL, projectPath)
		payload = map[string]interface{}{
			"title":         title,
			"source_branch": branchName,
			"target_branch": baseBranch,
			"description":   description,
		}
		if len(labels) > 0 {
			payload["labels"] = strings.Join(labels, ",")
		}
		headers = map[string]string{
			"PRIVATE-TOKEN": credentials.token,
			"Content-Type":  "application/json",
		}

	case "bitbucket":
		workspace, err := extractWorkspaceFromURL(repoURL)
		if err != nil {
			return nil, fmt.Errorf("failed to extract workspace: %w", err)
		}
		repo := extractRepositoryFromURL(repoURL)
		endpoint = fmt.Sprintf("%s/repositories/%s/%s/pullrequests", apiBaseURL, workspace, repo)
		payload = map[string]interface{}{
			"title": map[string]string{"raw": title},
			"source": map[string]interface{}{
				"branch": map[string]string{"name": branchName},
			},
			"destination": map[string]interface{}{
				"branch": map[string]string{"name": baseBranch},
			},
			"description": map[string]string{"raw": description},
		}
		headers = map[string]string{
			"Authorization": "Bearer " + credentials.token,
			"Content-Type":  "application/json",
		}

	default:
		return nil, fmt.Errorf("unsupported Git provider: %s", provider)
	}

	body, err := gitAPIRequest(ctx, "POST", endpoint, payload, headers, tlsVerify)
	if err != nil {
		// Sanitize endpoint and error to prevent token leakage
		sanitizedEndpoint := sanitizeString(endpoint, credentials)
		sanitizedErr := sanitizeError(err, credentials)
		return nil, fmt.Errorf("failed to create PR at endpoint %s: %w", sanitizedEndpoint, sanitizedErr)
	}

	var pr pullRequest
	switch provider {
	case "github":
		var gh struct {
			Number int    `json:"number"`
			State  string `json:"state"`
			URL    string `json:"html_url"`
		}
		if err := json.Unmarshal(body, &gh); err != nil {
			return nil, fmt.Errorf("failed to decode response: %w", err)
		}
		pr.Number = gh.Number
		pr.URL = gh.URL
		pr.State = strings.ToUpper(gh.State)

	case "gitlab":
		var gl struct {
			IID   int    `json:"iid"`
			State string `json:"state"`
			URL   string `json:"web_url"`
		}
		if err := json.Unmarshal(body, &gl); err != nil {
			return nil, fmt.Errorf("failed to decode response: %w", err)
		}
		pr.Number = gl.IID
		pr.URL = gl.URL
		pr.State = strings.ToUpper(gl.State)

	case "bitbucket":
		var bb struct {
			ID    int    `json:"id"`
			State string `json:"state"`
			Links struct {
				HTML struct {
					Href string `json:"href"`
				} `json:"html"`
			} `json:"links"`
		}
		if err := json.Unmarshal(body, &bb); err != nil {
			return nil, fmt.Errorf("failed to decode response: %w", err)
		}
		pr.Number = bb.ID
		pr.URL = bb.Links.HTML.Href
		pr.State = strings.ToUpper(bb.State)
	}

	return &pr, nil
}

// getPRByBranch gets PR by branch name from Git provider.
// Returns nil if PR not found (not an error).
// tlsVerify controls TLS certificate verification (false = skip verification, insecure).
func getPRByBranch(ctx context.Context, provider, apiBaseURL, repoURL, branchName string, credentials *gitCredentials, tlsVerify bool) (*pullRequest, error) {
	var endpoint string
	var headers map[string]string

	u, err := neturl.Parse(repoURL)
	if err != nil {
		return nil, fmt.Errorf("failed to parse repo URL: %w", err)
	}

	switch provider {
	case "github":
		parts := strings.Split(strings.Trim(u.Path, "/"), "/")
		if len(parts) < 2 {
			return nil, fmt.Errorf("invalid GitHub repo URL: %s", repoURL)
		}
		owner := parts[0]
		endpoint = fmt.Sprintf("%s/repos/%s/%s/pulls?head=%s:%s&state=all", apiBaseURL, owner, strings.TrimSuffix(parts[1], ".git"), owner, branchName)
		headers = map[string]string{
			"Authorization": "token " + credentials.token,
			"Accept":        "application/vnd.github.v3+json",
		}

	case "gitlab":
		projectPath := strings.TrimSuffix(strings.TrimPrefix(u.Path, "/"), ".git")
		projectPath = neturl.PathEscape(projectPath)
		endpoint = fmt.Sprintf("%s/projects/%s/merge_requests?source_branch=%s&state=all", apiBaseURL, projectPath, branchName)
		headers = map[string]string{
			"PRIVATE-TOKEN": credentials.token,
		}

	case "bitbucket":
		workspace, err := extractWorkspaceFromURL(repoURL)
		if err != nil {
			return nil, fmt.Errorf("failed to extract workspace: %w", err)
		}
		repo := extractRepositoryFromURL(repoURL)
		endpoint = fmt.Sprintf("%s/repositories/%s/%s/pullrequests?state=ALL", apiBaseURL, workspace, repo)
		headers = map[string]string{
			"Authorization": "Bearer " + credentials.token,
		}

	default:
		return nil, fmt.Errorf("unsupported Git provider: %s", provider)
	}

	body, err := gitAPIRequest(ctx, "GET", endpoint, nil, headers, tlsVerify)
	if err != nil {
		if strings.Contains(err.Error(), "404") {
			return nil, nil // PR not found
		}
		return nil, err
	}

	switch provider {
	case "github":
		var prs []struct {
			Number  int    `json:"number"`
			State   string `json:"state"`
			HTMLURL string `json:"html_url"`
		}
		if err := json.Unmarshal(body, &prs); err != nil {
			return nil, fmt.Errorf("failed to decode response: %w", err)
		}
		if len(prs) == 0 {
			return nil, nil
		}
		return &pullRequest{Number: prs[0].Number, URL: prs[0].HTMLURL, State: strings.ToUpper(prs[0].State)}, nil

	case "gitlab":
		var mrs []struct {
			IID   int    `json:"iid"`
			State string `json:"state"`
			URL   string `json:"web_url"`
		}
		if err := json.Unmarshal(body, &mrs); err != nil {
			return nil, fmt.Errorf("failed to decode response: %w", err)
		}
		if len(mrs) == 0 {
			return nil, nil
		}
		return &pullRequest{Number: mrs[0].IID, URL: mrs[0].URL, State: strings.ToUpper(mrs[0].State)}, nil

	case "bitbucket":
		var resp struct {
			Values []struct {
				ID    int    `json:"id"`
				State string `json:"state"`
				Links struct {
					HTML struct {
						Href string `json:"href"`
					} `json:"html"`
				} `json:"links"`
				Source struct {
					Branch struct {
						Name string `json:"name"`
					} `json:"branch"`
				} `json:"source"`
			} `json:"values"`
		}
		if err := json.Unmarshal(body, &resp); err != nil {
			return nil, fmt.Errorf("failed to decode response: %w", err)
		}
		for _, pr := range resp.Values {
			if pr.Source.Branch.Name == branchName {
				return &pullRequest{Number: pr.ID, URL: pr.Links.HTML.Href, State: strings.ToUpper(pr.State)}, nil
			}
		}
		return nil, nil
	}

	return nil, nil
}

// mergePullRequest merges a PR using Git provider API.
// Supports GitHub, GitLab, and Bitbucket merge operations.
// tlsVerify controls TLS certificate verification (false = skip verification, insecure).
func mergePullRequest(ctx context.Context, provider, apiBaseURL, repoURL string, prNumber int, credentials *gitCredentials, tlsVerify bool) error {
	var endpoint string
	var payload map[string]interface{}
	var headers map[string]string

	u, err := neturl.Parse(repoURL)
	if err != nil {
		return fmt.Errorf("failed to parse repo URL: %w", err)
	}

	switch provider {
	case "github":
		parts := strings.Split(strings.Trim(u.Path, "/"), "/")
		if len(parts) < 2 {
			return fmt.Errorf("invalid GitHub repo URL: %s", repoURL)
		}
		endpoint = fmt.Sprintf("%s/repos/%s/%s/pulls/%d/merge", apiBaseURL, parts[0], strings.TrimSuffix(parts[1], ".git"), prNumber)
		payload = map[string]interface{}{"merge_method": "merge"}
		headers = map[string]string{
			"Authorization": "token " + credentials.token,
			"Content-Type":  "application/json",
			"Accept":        "application/vnd.github.v3+json",
		}

	case "gitlab":
		projectPath := strings.TrimSuffix(strings.TrimPrefix(u.Path, "/"), ".git")
		projectPath = neturl.PathEscape(projectPath)
		endpoint = fmt.Sprintf("%s/projects/%s/merge_requests/%d/merge", apiBaseURL, projectPath, prNumber)
		headers = map[string]string{
			"PRIVATE-TOKEN": credentials.token,
		}

	case "bitbucket":
		workspace, err := extractWorkspaceFromURL(repoURL)
		if err != nil {
			return fmt.Errorf("failed to extract workspace: %w", err)
		}
		repo := extractRepositoryFromURL(repoURL)
		endpoint = fmt.Sprintf("%s/repositories/%s/%s/pullrequests/%d/merge", apiBaseURL, workspace, repo, prNumber)
		headers = map[string]string{
			"Authorization": "Bearer " + credentials.token,
		}

	default:
		return fmt.Errorf("unsupported Git provider: %s", provider)
	}

	_, err = gitAPIRequest(ctx, "PUT", endpoint, payload, headers, tlsVerify)
	return err
}

// deleteBranch deletes a branch using Git provider API.
// Returns nil if branch doesn't exist (404 error).
// tlsVerify controls TLS certificate verification (false = skip verification, insecure).
func deleteBranch(ctx context.Context, provider, apiBaseURL, repoURL, branchName string, credentials *gitCredentials, tlsVerify bool) error {
	var endpoint string
	var headers map[string]string

	u, err := neturl.Parse(repoURL)
	if err != nil {
		return fmt.Errorf("failed to parse repo URL: %w", err)
	}

	switch provider {
	case "github":
		parts := strings.Split(strings.Trim(u.Path, "/"), "/")
		if len(parts) < 2 {
			return fmt.Errorf("invalid GitHub repo URL: %s", repoURL)
		}
		endpoint = fmt.Sprintf("%s/repos/%s/%s/git/refs/heads/%s", apiBaseURL, parts[0], strings.TrimSuffix(parts[1], ".git"), branchName)
		headers = map[string]string{
			"Authorization": "token " + credentials.token,
		}

	case "gitlab":
		projectPath := strings.TrimSuffix(strings.TrimPrefix(u.Path, "/"), ".git")
		projectPath = neturl.PathEscape(projectPath)
		endpoint = fmt.Sprintf("%s/projects/%s/repository/branches/%s", apiBaseURL, projectPath, branchName)
		headers = map[string]string{
			"PRIVATE-TOKEN": credentials.token,
		}

	case "bitbucket":
		workspace, err := extractWorkspaceFromURL(repoURL)
		if err != nil {
			return fmt.Errorf("failed to extract workspace: %w", err)
		}
		repo := extractRepositoryFromURL(repoURL)
		endpoint = fmt.Sprintf("%s/repositories/%s/%s/refs/branches/%s", apiBaseURL, workspace, repo, branchName)
		headers = map[string]string{
			"Authorization": "Bearer " + credentials.token,
		}

	default:
		return fmt.Errorf("unsupported Git provider: %s", provider)
	}

	_, err = gitAPIRequest(ctx, "DELETE", endpoint, nil, headers, tlsVerify)
	if err != nil && strings.Contains(err.Error(), "404") {
		return nil // Branch already doesn't exist
	}
	return err
}

