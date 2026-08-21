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
	"testing"
)

// TestParseWatchNamespaces tests the WATCH_NAMESPACE env var parsing
func TestParseWatchNamespaces(t *testing.T) {
	tests := []struct {
		name     string
		value    string
		expected []string
	}{
		{
			name:     "Empty value (unset) - cluster-wide behavior",
			value:    "",
			expected: nil,
		},
		{
			name:     "Single namespace",
			value:    "e2e-test-a",
			expected: []string{"e2e-test-a"},
		},
		{
			name:     "Multiple namespaces",
			value:    "e2e-test-a,app-ns-1,app-ns-2",
			expected: []string{"e2e-test-a", "app-ns-1", "app-ns-2"},
		},
		{
			name:     "Whitespace around namespaces is trimmed",
			value:    " e2e-test-a , app-ns-1 ",
			expected: []string{"e2e-test-a", "app-ns-1"},
		},
		{
			name:     "Empty segments are ignored",
			value:    "e2e-test-a,,app-ns-1",
			expected: []string{"e2e-test-a", "app-ns-1"},
		},
		{
			name:     "Only commas and whitespace - cluster-wide behavior",
			value:    " , ,",
			expected: nil,
		},
		{
			name:     "Trailing comma is ignored",
			value:    "e2e-test-a,",
			expected: []string{"e2e-test-a"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := parseWatchNamespaces(tt.value)

			if len(result) != len(tt.expected) {
				t.Errorf("Expected %d namespaces, got %d (%v)", len(tt.expected), len(result), result)
				return
			}
			for i, ns := range tt.expected {
				if result[i] != ns {
					t.Errorf("Expected namespace %q at index %d, got %q", ns, i, result[i])
				}
			}
		})
	}
}
