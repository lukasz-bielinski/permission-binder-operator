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
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// writeFile writes content to a file in the repo directory.
// Creates parent directories if they don't exist.
func writeFile(repoDir string, filePath string, content []byte) error {
	fullPath := filepath.Join(repoDir, filePath)
	if err := os.MkdirAll(filepath.Dir(fullPath), 0755); err != nil {
		return fmt.Errorf("failed to create directory: %w", err)
	}
	return os.WriteFile(fullPath, content, 0644)
}

// readFile reads a file from the repo directory.
func readFile(repoDir string, filePath string) ([]byte, error) {
	fullPath := filepath.Join(repoDir, filePath)
	return os.ReadFile(fullPath)
}

// fileExists checks if a file exists in the repo directory.
func fileExists(repoDir string, filePath string) bool {
	fullPath := filepath.Join(repoDir, filePath)
	_, err := os.Stat(fullPath)
	return err == nil
}

// listFiles lists YAML files in a directory.
// Returns only .yaml files, excluding subdirectories.
func listFiles(repoDir string, dirPath string) ([]string, error) {
	fullPath := filepath.Join(repoDir, dirPath)
	entries, err := os.ReadDir(fullPath)
	if err != nil {
		return nil, err
	}

	var files []string
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".yaml") {
			files = append(files, entry.Name())
		}
	}
	return files, nil
}

