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

package main

import (
	"fmt"
	"os"
	"strings"
)

// git-askpass-helper is a minimal binary helper for git credential operations.
// It reads credentials from environment variables (GIT_HTTP_USER, GIT_HTTP_PASSWORD)
// and outputs them when git requests username or password.
//
// SECURITY: This binary never exposes credentials in process arguments or logs.
// Credentials are only read from environment variables at runtime.
//
// Git calls this helper with prompts like:
//   - "Username for 'https://github.com':"
//   - "Password for 'https://user@github.com':"
func main() {
	if len(os.Args) < 2 {
		os.Exit(1)
	}

	prompt := strings.ToLower(os.Args[1])

	// Check if git is asking for username
	if strings.Contains(prompt, "username") {
		username := os.Getenv("GIT_HTTP_USER")
		if username != "" {
			fmt.Print(username)
			os.Exit(0)
		}
		os.Exit(1)
	}

	// Check if git is asking for password
	if strings.Contains(prompt, "password") {
		password := os.Getenv("GIT_HTTP_PASSWORD")
		if password != "" {
			fmt.Print(password)
			os.Exit(0)
		}
		os.Exit(1)
	}

	// Unknown prompt
	os.Exit(1)
}
