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

package controller

import (
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Helper function to check if a slice contains a string
func containsString(slice []string, s string) bool {
	for _, item := range slice {
		if item == s {
			return true
		}
	}
	return false
}

// Helper function to remove a string from a slice
func removeString(slice []string, s string) []string {
	var result []string
	for _, item := range slice {
		if item != s {
			result = append(result, item)
		}
	}
	return result
}

// getMapKeys returns the keys of a map as a slice (helper for error messages)
func getMapKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	return keys
}

// extractRoleFromRoleBindingName extracts the role from a role binding name
// This is a legacy function that only works for single-word roles (e.g., "edit", "view")
// For roles with hyphens (e.g., "read-only"), use extractRoleFromRoleBindingNameWithMapping
func (r *PermissionBinderReconciler) extractRoleFromRoleBindingName(name string) string {
	parts := strings.Split(name, "-")
	if len(parts) >= 2 {
		return parts[len(parts)-1]
	}
	return ""
}

// extractRoleFromRoleBindingNameWithMapping extracts the role from a role binding name
// by matching suffixes against role mapping keys. This supports roles with hyphens (e.g., "read-only").
// It tries to match the longest possible role name first to handle cases like "read-only" vs "only".
func (r *PermissionBinderReconciler) extractRoleFromRoleBindingNameWithMapping(name string, roleMapping map[string]string) string {
	// Sort role names by length (longest first) to match "read-only" before "only"
	roleNames := make([]string, 0, len(roleMapping))
	for roleName := range roleMapping {
		roleNames = append(roleNames, roleName)
	}

	// Simple sort by length (longest first)
	for i := 0; i < len(roleNames)-1; i++ {
		for j := i + 1; j < len(roleNames); j++ {
			if len(roleNames[i]) < len(roleNames[j]) {
				roleNames[i], roleNames[j] = roleNames[j], roleNames[i]
			}
		}
	}

	// Try to match each role name as a suffix of the RoleBinding name
	for _, roleName := range roleNames {
		suffix := "-" + roleName
		if strings.HasSuffix(name, suffix) {
			return roleName
		}
	}

	// Fallback to legacy behavior (last segment after split)
	parts := strings.Split(name, "-")
	if len(parts) >= 2 {
		return parts[len(parts)-1]
	}
	return ""
}

// roleExistsInMapping checks if a role exists in the role mapping
func (r *PermissionBinderReconciler) roleExistsInMapping(role string, mapping map[string]string) bool {
	_, exists := mapping[role]
	return exists
}

// findCondition finds a condition by type in the conditions slice
func findCondition(conditions []metav1.Condition, conditionType string) *metav1.Condition {
	for i := range conditions {
		if conditions[i].Type == conditionType {
			return &conditions[i]
		}
	}
	return nil
}

