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
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/log"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// ProcessConfigMapResult holds the results of processing a ConfigMap
type ProcessConfigMapResult struct {
	ProcessedRoleBindings    []string
	ProcessedServiceAccounts []string
}

// processConfigMap processes the ConfigMap data and creates RoleBindings
func (r *PermissionBinderReconciler) processConfigMap(ctx context.Context, permissionBinder *permissionv1.PermissionBinder, configMap *corev1.ConfigMap) (ProcessConfigMapResult, error) {
	logger := log.FromContext(ctx)
	result := ProcessConfigMapResult{}
	var processedRoleBindings []string
	var validWhitelistEntries []string // For LDAP group creation

	// Look for whitelist.txt key in ConfigMap
	whitelistContent, found := configMap.Data["whitelist.txt"]
	if !found {
		logger.Info("No whitelist.txt found in ConfigMap, skipping processing")
		return result, nil
	}

	// Parse whitelist.txt line by line
	lines := strings.Split(whitelistContent, "\n")
	for lineNum, line := range lines {
		line = strings.TrimSpace(line)

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Extract CN value from LDAP DN format
		// Example: CN=DD_0000-K8S-123-Cluster-admin,OU=Openshift-123,...
		cnValue, err := r.extractCNFromDN(line)
		if err != nil {
			configMapEntriesProcessed.WithLabelValues("error").Inc()
			logger.Info("Skipping invalid LDAP DN entry - cannot extract CN",
				"line", lineNum+1,
				"content", line,
				"reason", err.Error(),
				"action", "skip")
			continue
		}

		// Check if the CN value is in the exclude list
		if r.isExcluded(cnValue, permissionBinder.Spec.ExcludeList) {
			configMapEntriesProcessed.WithLabelValues("excluded").Inc()
			logger.Info("Skipping excluded CN", "cn", cnValue)
			continue
		}

		// Parse the CN value to extract namespace and role (try all prefixes)
		namespace, role, matchedPrefix, err := r.parsePermissionStringWithPrefixes(cnValue, permissionBinder.Spec.Prefixes, permissionBinder.Spec.RoleMapping)
		if err != nil {
			configMapEntriesProcessed.WithLabelValues("error").Inc()
			logger.Info("Skipping invalid permission string - cannot parse CN value",
				"line", lineNum+1,
				"cn", cnValue,
				"reason", err.Error(),
				"action", "skip")
			continue
		}

		logger.V(1).Info("Parsed permission string", "cn", cnValue, "prefix", matchedPrefix, "namespace", namespace, "role", role)

		// Add to valid entries for LDAP processing (use original line with full DN)
		validWhitelistEntries = append(validWhitelistEntries, line)

		// Ensure namespace exists
		if err := r.ensureNamespace(ctx, namespace, permissionBinder); err != nil {
			logger.Error(err, "Failed to ensure namespace exists", "namespace", namespace)
			continue
		}

		// Create RoleBinding (use the CN value as the group subject name)
		// OpenShift LDAP syncer creates groups with CN value as name, not full DN
		roleBindingName := fmt.Sprintf("%s-%s", namespace, role)
		if err := r.createRoleBinding(ctx, namespace, roleBindingName, role, cnValue, permissionBinder.Spec.RoleMapping[role], permissionBinder); err != nil {
			logger.Error(err, "Failed to create RoleBinding", "namespace", namespace, "role", role)
			continue
		}

		processedRoleBindings = append(processedRoleBindings, fmt.Sprintf("%s/%s", namespace, roleBindingName))
		configMapEntriesProcessed.WithLabelValues("success").Inc()
		logger.Info("Created RoleBinding", "namespace", namespace, "role", role, "groupName", cnValue)
	}

	// Process LDAP group creation if enabled
	if permissionBinder.Spec.CreateLdapGroups && len(validWhitelistEntries) > 0 {
		logger.Info("🔐 LDAP group creation is enabled, processing entries", "count", len(validWhitelistEntries))
		if err := r.ProcessLdapGroupCreation(ctx, permissionBinder, validWhitelistEntries); err != nil {
			// Log error but don't fail the entire reconciliation
			logger.Error(err, "⚠️  LDAP group creation failed (non-fatal)", "validEntries", len(validWhitelistEntries))
		}
	}

	// Process ServiceAccount creation if configured
	// ServiceAccounts are created per namespace based on serviceAccountMapping
	// This happens for each namespace that was processed above
	var allProcessedSAs []string
	if len(permissionBinder.Spec.ServiceAccountMapping) > 0 {
		// Get unique namespaces from processed RoleBindings
		namespaces := make(map[string]bool)
		for _, rb := range processedRoleBindings {
			// RoleBinding format: "namespace/rolebinding-name"
			parts := strings.Split(rb, "/")
			if len(parts) == 2 {
				namespaces[parts[0]] = true
			}
		}

		logger.Info("🔑 ServiceAccount mapping configured, creating ServiceAccounts",
			"mappings", len(permissionBinder.Spec.ServiceAccountMapping),
			"namespaces", len(namespaces))

		// Process each namespace
		for namespace := range namespaces {
			processedSAs, err := ProcessServiceAccounts(
				ctx,
				r.Client,
				namespace,
				permissionBinder.Spec.ServiceAccountMapping,
				permissionBinder.Spec.ServiceAccountNamingPattern,
				permissionBinder.Name,
			)
			if err != nil {
				// Log error but don't fail the entire reconciliation
				logger.Error(err, "⚠️  ServiceAccount creation failed (non-fatal)",
					"namespace", namespace)
			} else {
				allProcessedSAs = append(allProcessedSAs, processedSAs...)
				logger.Info("✅ ServiceAccounts processed successfully",
					"namespace", namespace,
					"created", len(processedSAs))
			}
		}

		// Update managedServiceAccountsTotal metric
		managedServiceAccountsTotal.Set(float64(len(allProcessedSAs)))
	}

	// Populate result
	result.ProcessedRoleBindings = processedRoleBindings
	result.ProcessedServiceAccounts = allProcessedSAs

	return result, nil
}

// extractCNFromDN extracts the CN (Common Name) value from an LDAP DN string
// Example: "CN=DD_0000-K8S-123-admin,OU=..." -> "DD_0000-K8S-123-admin"
func (r *PermissionBinderReconciler) extractCNFromDN(dn string) (string, error) {
	// Find CN= prefix
	cnPrefix := "CN="
	cnIndex := strings.Index(dn, cnPrefix)
	if cnIndex == -1 {
		return "", fmt.Errorf("CN not found in DN: %s", dn)
	}

	// Extract everything after CN=
	afterCN := dn[cnIndex+len(cnPrefix):]

	// Find the end of CN value (marked by comma)
	commaIndex := strings.Index(afterCN, ",")
	if commaIndex == -1 {
		// No comma found, use the entire remaining string
		return strings.TrimSpace(afterCN), nil
	}

	// Extract CN value up to the comma
	cnValue := strings.TrimSpace(afterCN[:commaIndex])
	return cnValue, nil
}

// isExcluded checks if a key is in the exclude list
func (r *PermissionBinderReconciler) isExcluded(key string, excludeList []string) bool {
	for _, excluded := range excludeList {
		if key == excluded {
			return true
		}
	}
	return false
}

// parsePermissionStringWithPrefixes tries to parse permission string with multiple prefixes
// Returns namespace, role, matched prefix, and error
func (r *PermissionBinderReconciler) parsePermissionStringWithPrefixes(permissionString string, prefixes []string, roleMapping map[string]string) (string, string, string, error) {
	// Try each prefix (longest first to handle overlapping prefixes like "MT-K8S-DEV" and "MT-K8S")
	sortedPrefixes := make([]string, len(prefixes))
	copy(sortedPrefixes, prefixes)

	// Sort by length descending (longest first)
	for i := 0; i < len(sortedPrefixes); i++ {
		for j := i + 1; j < len(sortedPrefixes); j++ {
			if len(sortedPrefixes[j]) > len(sortedPrefixes[i]) {
				sortedPrefixes[i], sortedPrefixes[j] = sortedPrefixes[j], sortedPrefixes[i]
			}
		}
	}

	for _, prefix := range sortedPrefixes {
		namespace, role, err := r.parsePermissionString(permissionString, prefix, roleMapping)
		if err == nil {
			return namespace, role, prefix, nil
		}
	}

	return "", "", "", fmt.Errorf("no matching prefix found for: %s (available prefixes: %v)", permissionString, prefixes)
}

// parsePermissionString parses a permission string like "COMPANY-K8S-project-123-engineer"
// and returns namespace and role. The role is determined by checking against roleMapping keys,
// which allows namespaces to contain hyphens (e.g., "project-123").
// If multiple roles match, the longest role name is used (e.g., "read-only" before "only").
func (r *PermissionBinderReconciler) parsePermissionString(permissionString, prefix string, roleMapping map[string]string) (string, string, error) {
	// Remove prefix
	withoutPrefix := strings.TrimPrefix(permissionString, prefix+"-")
	if withoutPrefix == permissionString {
		return "", "", fmt.Errorf("permission string does not start with prefix: %s", prefix)
	}

	// Try to match known roles from roleMapping by checking suffixes
	// This allows namespaces to contain hyphens (e.g., "project-123-engineer" where role="engineer" and namespace="project-123")
	// If multiple roles match, prefer the longest one (e.g., "read-only" over "only")
	var matchedRole string
	var namespace string
	var maxRoleLength int

	for role := range roleMapping {
		// Check if the string ends with "-{role}"
		suffix := "-" + role
		if strings.HasSuffix(withoutPrefix, suffix) {
			// Found a matching role - prefer longer role names
			if len(role) > maxRoleLength {
				matchedRole = role
				namespace = strings.TrimSuffix(withoutPrefix, suffix)
				maxRoleLength = len(role)
			}
		}
	}

	if matchedRole == "" {
		return "", "", fmt.Errorf("no matching role found in roleMapping for: %s (available roles: %v)", permissionString, getMapKeys(roleMapping))
	}

	if namespace == "" {
		return "", "", fmt.Errorf("invalid permission string format: namespace cannot be empty in %s", permissionString)
	}

	return namespace, matchedRole, nil
}

// calculateRoleMappingHash calculates a hash of the role mapping for change detection
func (r *PermissionBinderReconciler) calculateRoleMappingHash(roleMapping map[string]string) string {
	// Sort keys for consistent hashing
	keys := make([]string, 0, len(roleMapping))
	for k := range roleMapping {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	// Build deterministic string representation
	var builder strings.Builder
	for _, k := range keys {
		builder.WriteString(k)
		builder.WriteString("=")
		builder.WriteString(roleMapping[k])
		builder.WriteString(";")
	}

	// Calculate SHA256 hash
	hash := sha256.Sum256([]byte(builder.String()))
	return hex.EncodeToString(hash[:])
}

// hasRoleMappingChanged checks if the role mapping has changed
// Returns (changed bool, currentHash string)
func (r *PermissionBinderReconciler) hasRoleMappingChanged(pb *permissionv1.PermissionBinder) (bool, string) {
	currentHash := r.calculateRoleMappingHash(pb.Spec.RoleMapping)
	lastHash := pb.Status.LastProcessedRoleMappingHash

	// If no previous hash, consider it changed (first time)
	if lastHash == "" {
		return true, currentHash
	}

	// Compare hashes
	return currentHash != lastHash, currentHash
}

