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
	"testing"

	"github.com/stretchr/testify/assert"
	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// ============================================================================
// Namespace Management Tests
// ============================================================================

func TestIsNamespaceExcluded(t *testing.T) {
	tests := []struct {
		name        string
		namespace   string
		excludeList *permissionv1.NamespaceExcludeList
		expected    bool
	}{
		{
			name:      "Namespace in explicit list",
			namespace: "kube-system",
			excludeList: &permissionv1.NamespaceExcludeList{
				Explicit: []string{"kube-system", "kube-public"},
			},
			expected: true,
		},
		{
			name:      "Namespace matches pattern",
			namespace: "openshift-monitoring",
			excludeList: &permissionv1.NamespaceExcludeList{
				Patterns: []string{"^openshift-.*", "^kube-.*"},
			},
			expected: true,
		},
		{
			name:      "Namespace not excluded",
			namespace: "my-app",
			excludeList: &permissionv1.NamespaceExcludeList{
				Explicit: []string{"kube-system"},
				Patterns: []string{"^openshift-.*"},
			},
			expected: false,
		},
		{
			name:      "Nil exclude list",
			namespace: "my-app",
			excludeList: nil,
			expected: false,
		},
		{
			name:      "Empty exclude list",
			namespace: "my-app",
			excludeList: &permissionv1.NamespaceExcludeList{},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := IsNamespaceExcluded(tt.namespace, tt.excludeList)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestIsNamespaceExcludedFromBackup(t *testing.T) {
	tests := []struct {
		name        string
		namespace   string
		excludeList *permissionv1.NamespaceExcludeList
		expected    bool
	}{
		{
			name:      "Namespace excluded from backup",
			namespace: "my-app",
			excludeList: &permissionv1.NamespaceExcludeList{
				Explicit: []string{"my-app"},
			},
			expected: true,
		},
		{
			name:      "Namespace not excluded from backup",
			namespace: "other-app",
			excludeList: &permissionv1.NamespaceExcludeList{
				Explicit: []string{"my-app"},
			},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := isNamespaceExcludedFromBackup(tt.namespace, tt.excludeList)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestShouldBackupExistingPolicy(t *testing.T) {
	tests := []struct {
		name                  string
		namespace             string
		backupExisting        bool
		excludeBackupForNamespaces *permissionv1.NamespaceExcludeList
		expected              bool
	}{
		{
			name:          "Backup enabled, namespace not excluded",
			namespace:     "my-app",
			backupExisting: true,
			excludeBackupForNamespaces: nil,
			expected:      true,
		},
		{
			name:          "Backup disabled",
			namespace:     "my-app",
			backupExisting: false,
			excludeBackupForNamespaces: nil,
			expected:      false,
		},
		{
			name:          "Backup enabled but namespace excluded",
			namespace:     "my-app",
			backupExisting: true,
			excludeBackupForNamespaces: &permissionv1.NamespaceExcludeList{
				Explicit: []string{"my-app"},
			},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := shouldBackupExistingPolicy(tt.namespace, tt.backupExisting, tt.excludeBackupForNamespaces)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestChunkNamespaces(t *testing.T) {
	tests := []struct {
		name      string
		namespaces []string
		batchSize int
		expectedBatches int
	}{
		{
			name:      "Single batch",
			namespaces: []string{"ns1", "ns2", "ns3"},
			batchSize: 5,
			expectedBatches: 1,
		},
		{
			name:      "Multiple batches",
			namespaces: []string{"ns1", "ns2", "ns3", "ns4", "ns5", "ns6"},
			batchSize: 2,
			expectedBatches: 3,
		},
		{
			name:      "Empty list",
			namespaces: []string{},
			batchSize: 5,
			expectedBatches: 0,
		},
		{
			name:      "Exact batch size",
			namespaces: []string{"ns1", "ns2", "ns3", "ns4", "ns5"},
			batchSize: 5,
			expectedBatches: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			batches := chunkNamespaces(tt.namespaces, tt.batchSize)
			assert.Equal(t, tt.expectedBatches, len(batches))

			// Verify all namespaces are included
			totalNamespaces := 0
			for _, batch := range batches {
				totalNamespaces += len(batch)
			}
			assert.Equal(t, len(tt.namespaces), totalNamespaces)
		})
	}
}

