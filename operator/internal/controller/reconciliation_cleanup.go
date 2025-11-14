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
	"fmt"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/selection"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// cleanupManagedResources cleans up all resources managed by this PermissionBinder
// SAFE MODE: We do NOT delete RoleBindings or namespaces when PermissionBinder is deleted
// This prevents cascade failures and accidental data loss
func (r *PermissionBinderReconciler) cleanupManagedResources(ctx context.Context, permissionBinder *permissionv1.PermissionBinder) error {
	logger := log.FromContext(ctx)

	logger.Info("PermissionBinder is being deleted - SAFE MODE: RoleBindings and namespaces will be preserved to prevent cascade failures")

	// Get all managed role bindings to add cleanup annotation
	roleBindings, err := r.getManagedRoleBindings(ctx, permissionBinder)
	if err != nil {
		logger.Error(err, "Failed to get managed role bindings for annotation")
	} else {
		for _, roleBinding := range roleBindings {
			// Add annotation indicating PermissionBinder was deleted but RoleBinding is preserved
			if roleBinding.Annotations == nil {
				roleBinding.Annotations = make(map[string]string)
			}
			roleBinding.Annotations["permission-binder.io/orphaned-at"] = time.Now().Format(time.RFC3339)
			roleBinding.Annotations["permission-binder.io/orphaned-by"] = "permission-binder-deletion"

			if err := r.Update(ctx, &roleBinding); err != nil {
				logger.Error(err, "Failed to annotate RoleBinding as orphaned", "namespace", roleBinding.Namespace, "name", roleBinding.Name)
			} else {
				logger.Info("Annotated RoleBinding as orphaned", "namespace", roleBinding.Namespace, "name", roleBinding.Name)
			}
		}
	}

	// Get all managed namespaces to add cleanup annotation
	namespaces, err := r.getManagedNamespaces(ctx, permissionBinder)
	if err != nil {
		logger.Error(err, "Failed to get managed namespaces for annotation")
	} else {
		for _, namespace := range namespaces {
			var ns corev1.Namespace
			if err := r.Get(ctx, types.NamespacedName{Name: namespace}, &ns); err != nil {
				logger.Error(err, "Failed to get namespace for annotation", "namespace", namespace)
				continue
			}

			// Add annotation indicating PermissionBinder was deleted but namespace is preserved
			if ns.Annotations == nil {
				ns.Annotations = make(map[string]string)
			}
			ns.Annotations["permission-binder.io/orphaned-at"] = time.Now().Format(time.RFC3339)
			ns.Annotations["permission-binder.io/orphaned-by"] = "permission-binder-deletion"

			if err := r.Update(ctx, &ns); err != nil {
				logger.Error(err, "Failed to annotate namespace as orphaned", "namespace", namespace)
			} else {
				logger.Info("Annotated namespace as orphaned", "namespace", namespace)
			}
		}
	}

	logger.Info("SAFE MODE cleanup completed - all managed resources preserved with orphaned annotations")
	return nil
}

// getManagedNamespaces returns all namespaces managed by this PermissionBinder
func (r *PermissionBinderReconciler) getManagedNamespaces(ctx context.Context, permissionBinder *permissionv1.PermissionBinder) ([]string, error) {
	var namespaces corev1.NamespaceList

	// Create label selector for managed namespaces
	selector := labels.NewSelector()
	req, err := labels.NewRequirement(LabelManagedBy, selection.Equals, []string{ManagedByValue})
	if err != nil {
		return nil, err
	}
	selector = selector.Add(*req)

	if err := r.List(ctx, &namespaces, &client.ListOptions{LabelSelector: selector}); err != nil {
		return nil, err
	}

	var result []string
	for _, ns := range namespaces.Items {
		// Filter by permission binder annotation
		if ns.Annotations != nil && ns.Annotations[AnnotationPermissionBinder] == permissionBinder.Name {
			result = append(result, ns.Name)
		}
	}

	return result, nil
}

// getManagedRoleBindings returns all role bindings managed by this PermissionBinder
func (r *PermissionBinderReconciler) getManagedRoleBindings(ctx context.Context, permissionBinder *permissionv1.PermissionBinder) ([]rbacv1.RoleBinding, error) {
	var roleBindings rbacv1.RoleBindingList

	// Create label selector for managed role bindings
	selector := labels.NewSelector()
	req, err := labels.NewRequirement(LabelManagedBy, selection.Equals, []string{ManagedByValue})
	if err != nil {
		return nil, err
	}
	selector = selector.Add(*req)

	if err := r.List(ctx, &roleBindings, &client.ListOptions{LabelSelector: selector}); err != nil {
		return nil, err
	}

	// Filter by permission binder annotation
	var result []rbacv1.RoleBinding
	for _, rb := range roleBindings.Items {
		if rb.Annotations != nil && rb.Annotations[AnnotationPermissionBinder] == permissionBinder.Name {
			result = append(result, rb)
		}
	}

	return result, nil
}

// reconcileAllManagedResources reconciles all managed resources when role mapping changes
func (r *PermissionBinderReconciler) reconcileAllManagedResources(ctx context.Context, permissionBinder *permissionv1.PermissionBinder) error {
	logger := log.FromContext(ctx)

	// Get all managed namespaces
	managedNamespaces, err := r.getManagedNamespaces(ctx, permissionBinder)
	if err != nil {
		return fmt.Errorf("failed to get managed namespaces: %w", err)
	}

	// Get all managed role bindings
	managedRoleBindings, err := r.getManagedRoleBindings(ctx, permissionBinder)
	if err != nil {
		return fmt.Errorf("failed to get managed role bindings: %w", err)
	}

	// Note: We intentionally do NOT check for missing RoleBindings here
	// RoleBindings are created by processConfigMap() which respects excludeList
	// Missing RoleBindings could be intentional (excluded CNs) or will be recreated
	// on next ConfigMap reconciliation
	logger.V(1).Info("Managed namespaces found", "count", len(managedNamespaces))

	// Remove role bindings for roles that no longer exist in mapping
	for _, roleBinding := range managedRoleBindings {
		// Try to get role from annotation first (supports roles with hyphens like "read-only")
		role := ""
		if roleBinding.Annotations != nil {
			role = roleBinding.Annotations[AnnotationRole]
		}

		// Fallback to extracting from name if annotation not present (backward compatibility)
		if role == "" {
			role = r.extractRoleFromRoleBindingNameWithMapping(roleBinding.Name, permissionBinder.Spec.RoleMapping)
		}

		if role != "" && !r.roleExistsInMapping(role, permissionBinder.Spec.RoleMapping) {
			if err := r.Delete(ctx, &roleBinding); err != nil {
				logger.Error(err, "Failed to delete obsolete RoleBinding", "namespace", roleBinding.Namespace, "name", roleBinding.Name)
			} else {
				logger.Info("Deleted obsolete RoleBinding", "namespace", roleBinding.Namespace, "name", roleBinding.Name)
			}
		}
	}

	// Remove role bindings that don't match any current prefix
	for _, roleBinding := range managedRoleBindings {
		if len(roleBinding.Subjects) > 0 {
			groupName := roleBinding.Subjects[0].Name
			matchesAnyPrefix := false
			for _, prefix := range permissionBinder.Spec.Prefixes {
				if strings.HasPrefix(groupName, prefix+"-") {
					matchesAnyPrefix = true
					break
				}
			}
			if !matchesAnyPrefix {
				if err := r.Delete(ctx, &roleBinding); err != nil {
					logger.Error(err, "Failed to delete RoleBinding with invalid prefix", "namespace", roleBinding.Namespace, "name", roleBinding.Name, "group", groupName)
				} else {
					logger.Info("Deleted RoleBinding with invalid prefix", "namespace", roleBinding.Namespace, "name", roleBinding.Name, "group", groupName)
				}
			}
		}
	}

	return nil
}

