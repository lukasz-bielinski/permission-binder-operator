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
	"regexp"
	"strings"
)

// sanitizeError removes sensitive information (tokens, passwords, credentials) from error messages.
// This prevents credential leakage in logs and error messages.
func sanitizeError(err error, credentials *gitCredentials) error {
	if err == nil {
		return nil
	}

	errMsg := err.Error()

	// Remove token if present
	if credentials != nil && credentials.token != "" {
		errMsg = strings.ReplaceAll(errMsg, credentials.token, "[REDACTED]")
		// Also replace common token patterns
		errMsg = regexp.MustCompile(`(?i)(token|bearer|private-token|authorization)[\s:=]+[a-zA-Z0-9_-]{20,}`).ReplaceAllString(errMsg, "$1 [REDACTED]")
	}

	// Remove username if present (might be sensitive)
	if credentials != nil && credentials.username != "" {
		// Only redact if it's not a default username
		if credentials.username != "permission-binder-operator" {
			errMsg = strings.ReplaceAll(errMsg, credentials.username, "[REDACTED]")
		}
	}

	// Remove common credential patterns from URLs
	errMsg = regexp.MustCompile(`://[^:]+:[^@]+@`).ReplaceAllString(errMsg, "://[REDACTED]:[REDACTED]@")
	errMsg = regexp.MustCompile(`(token|password|secret|key)[\s:=]+[a-zA-Z0-9_-]{10,}`).ReplaceAllStringFunc(errMsg, func(match string) string {
		parts := regexp.MustCompile(`[\s:=]+`).Split(match, 2)
		if len(parts) == 2 {
			return parts[0] + " [REDACTED]"
		}
		return match
	})

	return &sanitizedError{
		original: err,
		message:  errMsg,
	}
}

// sanitizeString removes sensitive information from strings (for logging).
func sanitizeString(s string, credentials *gitCredentials) string {
	if credentials == nil {
		return s
	}

	result := s

	// Remove token if present
	if credentials.token != "" {
		result = strings.ReplaceAll(result, credentials.token, "[REDACTED]")
		// Also replace common token patterns
		result = regexp.MustCompile(`(?i)(token|bearer|private-token|authorization)[\s:=]+[a-zA-Z0-9_-]{20,}`).ReplaceAllString(result, "$1 [REDACTED]")
	}

	// Remove username if present (might be sensitive)
	if credentials.username != "" && credentials.username != "permission-binder-operator" {
		result = strings.ReplaceAll(result, credentials.username, "[REDACTED]")
	}

	// Remove common credential patterns from URLs
	result = regexp.MustCompile(`://[^:]+:[^@]+@`).ReplaceAllString(result, "://[REDACTED]:[REDACTED]@")
	result = regexp.MustCompile(`(token|password|secret|key)[\s:=]+[a-zA-Z0-9_-]{10,}`).ReplaceAllStringFunc(result, func(match string) string {
		parts := regexp.MustCompile(`[\s:=]+`).Split(match, 2)
		if len(parts) == 2 {
			return parts[0] + " [REDACTED]"
		}
		return match
	})

	return result
}

// sanitizedError wraps an error with a sanitized message.
type sanitizedError struct {
	original error
	message  string
}

func (e *sanitizedError) Error() string {
	return e.message
}

func (e *sanitizedError) Unwrap() error {
	return e.original
}

