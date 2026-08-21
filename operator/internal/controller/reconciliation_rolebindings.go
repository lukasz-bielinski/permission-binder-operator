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
	"reflect"
	"time"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/log"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// ensureNamespace creates a namespace if it doesn't exist
func (r *PermissionBinderReconciler) ensureNamespace(ctx context.Context, namespace string, permissionBinder *permissionv1.PermissionBinder) error {
	logger := log.FromContext(ctx)
	var ns corev1.Namespace
	err := r.Get(ctx, types.NamespacedName{Name: namespace}, &ns)
	if err != nil {
		if errors.IsNotFound(err) {
			// Create namespace with annotations
			now := time.Now().Format(time.RFC3339)
			ns = corev1.Namespace{
				ObjectMeta: metav1.ObjectMeta{
					Name: namespace,
					Annotations: map[string]string{
						AnnotationManagedBy:                 ManagedByValue,
						AnnotationCreatedAt:                 now,
						AnnotationPermissionBinder:          permissionBinder.Name,
						AnnotationPermissionBinderNamespace: permissionBinder.Namespace,
					},
					Labels: map[string]string{
						LabelManagedBy: ManagedByValue,
					},
				},
			}
			if err := r.Create(ctx, &ns); err != nil {
				return fmt.Errorf("failed to create namespace %s: %w", namespace, err)
			}
		} else {
			return fmt.Errorf("failed to get namespace %s: %w", namespace, err)
		}
	} else {
		// OWNERSHIP GATE (issue #43): never take over a namespace with a live
		// claim by another PermissionBinder. Unclaimed, own, legacy name-only
		// and explicitly orphaned namespaces remain adoptable.
		if !canTakeOwnership(ns.Annotations, permissionBinder.Name, permissionBinder.Namespace) {
			ownershipConflictsTotal.WithLabelValues("namespace").Inc()
			logger.Info("Refusing to take ownership of namespace claimed by another PermissionBinder",
				"namespace", namespace,
				"claimedBy", ns.Annotations[AnnotationPermissionBinder],
				"claimedByNamespace", ns.Annotations[AnnotationPermissionBinderNamespace],
				"reconciledBy", permissionBinder.Name,
				"reconciledByNamespace", permissionBinder.Namespace)
			return nil
		}

		// Update existing namespace with annotations if not present
		needsUpdate := false
		if ns.Annotations == nil {
			ns.Annotations = make(map[string]string)
		}
		if ns.Labels == nil {
			ns.Labels = make(map[string]string)
		}

		// ADOPTION LOGIC: Remove orphaned annotations if present
		// This allows automatic recovery when PermissionBinder is recreated
		if ns.Annotations[AnnotationOrphanedAt] != "" {
			delete(ns.Annotations, AnnotationOrphanedAt)
			delete(ns.Annotations, AnnotationOrphanedBy)
			needsUpdate = true

			// Increment adoption metrics (automatic recovery)
			adoptionEventsTotal.Inc()

			logger.Info("Adopted orphaned namespace - removed orphaned annotations",
				"namespace", namespace,
				"permissionBinder", permissionBinder.Name,
				"action", "adoption",
				"recovery", "automatic")
		}

		if ns.Annotations[AnnotationManagedBy] != ManagedByValue {
			ns.Annotations[AnnotationManagedBy] = ManagedByValue
			needsUpdate = true
		}
		if ns.Annotations[AnnotationPermissionBinder] != permissionBinder.Name {
			ns.Annotations[AnnotationPermissionBinder] = permissionBinder.Name
			needsUpdate = true
		}
		if ns.Annotations[AnnotationPermissionBinderNamespace] != permissionBinder.Namespace {
			ns.Annotations[AnnotationPermissionBinderNamespace] = permissionBinder.Namespace
			needsUpdate = true
		}
		if ns.Annotations[AnnotationCreatedAt] == "" {
			ns.Annotations[AnnotationCreatedAt] = time.Now().Format(time.RFC3339)
			needsUpdate = true
		}
		if ns.Labels[LabelManagedBy] != ManagedByValue {
			ns.Labels[LabelManagedBy] = ManagedByValue
			needsUpdate = true
		}

		if needsUpdate {
			if err := r.Update(ctx, &ns); err != nil {
				return fmt.Errorf("failed to update namespace %s: %w", namespace, err)
			}
		}
	}
	return nil
}

// validateClusterRoleExists checks if the ClusterRole exists and logs a warning if it doesn't
// This is important for production environments to ensure proper RBAC configuration
func (r *PermissionBinderReconciler) validateClusterRoleExists(ctx context.Context, clusterRoleName string) bool {
	logger := log.FromContext(ctx)

	var clusterRole rbacv1.ClusterRole
	if err := r.Get(ctx, types.NamespacedName{Name: clusterRoleName}, &clusterRole); err != nil {
		if errors.IsNotFound(err) {
			// Increment metrics for missing ClusterRole (security critical!)
			missingClusterRoleTotal.WithLabelValues(clusterRoleName, "unknown").Inc()

			logger.Info("ClusterRole does not exist - RoleBinding will be created but will not grant permissions until ClusterRole is created",
				"clusterRole", clusterRoleName,
				"severity", "warning",
				"action_required", "create_clusterrole",
				"impact", "no_permissions_granted")
			return false
		}
		// Other errors (e.g., permission denied) - log but continue
		logger.Error(err, "Failed to check ClusterRole existence",
			"clusterRole", clusterRoleName,
			"severity", "error")
		return false
	}
	return true
}

// createRoleBinding ensures the desired RoleBinding exists and is owned by
// the given PermissionBinder. It returns managed=false (with a nil error) when
// the RoleBinding is claimed by another PermissionBinder and the ownership
// gate refused the takeover - the caller must not report such an entry as
// successfully processed.
func (r *PermissionBinderReconciler) createRoleBinding(ctx context.Context, namespace, name, role, group, clusterRole string, permissionBinder *permissionv1.PermissionBinder) (managed bool, err error) {
	logger := log.FromContext(ctx)
	now := time.Now().Format(time.RFC3339)

	// Validate ClusterRole exists before creating RoleBinding
	// This is a critical security check for production environments
	clusterRoleExists := r.validateClusterRoleExists(ctx, clusterRole)
	if !clusterRoleExists {
		logger.Info("Creating RoleBinding with non-existent ClusterRole",
			"namespace", namespace,
			"roleBinding", name,
			"clusterRole", clusterRole,
			"group", group,
			"severity", "warning",
			"security_impact", "high")
	}

	roleBinding := &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
			Annotations: map[string]string{
				AnnotationManagedBy:                 ManagedByValue,
				AnnotationCreatedAt:                 now,
				AnnotationPermissionBinder:          permissionBinder.Name,
				AnnotationPermissionBinderNamespace: permissionBinder.Namespace,
				AnnotationRole:                      role, // Store full role name to support roles with hyphens (e.g., "read-only")
			},
			Labels: map[string]string{
				LabelManagedBy: ManagedByValue,
			},
		},
		Subjects: []rbacv1.Subject{
			{
				Kind: "Group",
				Name: group,
			},
		},
		RoleRef: rbacv1.RoleRef{
			Kind:     "ClusterRole",
			Name:     clusterRole,
			APIGroup: "rbac.authorization.k8s.io",
		},
	}

	// Check if RoleBinding already exists
	var existing rbacv1.RoleBinding
	err = r.Get(ctx, types.NamespacedName{Name: name, Namespace: namespace}, &existing)
	if err != nil {
		if errors.IsNotFound(err) {
			// Create new RoleBinding
			if err := r.Create(ctx, roleBinding); err != nil {
				return false, fmt.Errorf("failed to create RoleBinding %s/%s: %w", namespace, name, err)
			}
		} else {
			return false, fmt.Errorf("failed to get RoleBinding %s/%s: %w", namespace, name, err)
		}
	} else {
		// OWNERSHIP GATE (issue #43): never overwrite a RoleBinding with a live
		// claim by another PermissionBinder (steal-then-delete prevention).
		// Gate is annotation-based ONLY - spec drift on an OWNED RoleBinding is
		// still reverted below (manual-modification protection, e2e test 15).
		if !canTakeOwnership(existing.Annotations, permissionBinder.Name, permissionBinder.Namespace) {
			ownershipConflictsTotal.WithLabelValues("rolebinding").Inc()
			logger.Info("Refusing to take ownership of RoleBinding claimed by another PermissionBinder",
				"namespace", namespace,
				"roleBinding", name,
				"claimedBy", existing.Annotations[AnnotationPermissionBinder],
				"claimedByNamespace", existing.Annotations[AnnotationPermissionBinderNamespace],
				"reconciledBy", permissionBinder.Name,
				"reconciledByNamespace", permissionBinder.Namespace)
			return false, nil
		}

		// Check if RoleBinding needs update - avoid unnecessary updates that change ResourceVersion
		needsUpdate := false
		hasOrphanedAnnotation := existing.Annotations[AnnotationOrphanedAt] != ""

		// Check if RoleRef changed
		if existing.RoleRef != roleBinding.RoleRef {
			needsUpdate = true
		}

		// Check if Subjects changed
		if !reflect.DeepEqual(existing.Subjects, roleBinding.Subjects) {
			needsUpdate = true
		}

		// Check if annotations need update
		if existing.Annotations == nil {
			existing.Annotations = make(map[string]string)
			needsUpdate = true
		}
		if existing.Labels == nil {
			existing.Labels = make(map[string]string)
			needsUpdate = true
		}

		// Check if managed-by annotation changed
		if existing.Annotations[AnnotationManagedBy] != ManagedByValue {
			needsUpdate = true
		}
		if existing.Annotations[AnnotationPermissionBinder] != permissionBinder.Name {
			needsUpdate = true
		}
		if existing.Annotations[AnnotationPermissionBinderNamespace] != permissionBinder.Namespace {
			needsUpdate = true
		}
		if existing.Annotations[AnnotationRole] != role {
			needsUpdate = true
		}
		if existing.Annotations[AnnotationCreatedAt] == "" {
			needsUpdate = true
		}
		if existing.Labels[LabelManagedBy] != ManagedByValue {
			needsUpdate = true
		}

		// Always update if orphaned annotation exists (adoption logic)
		if hasOrphanedAnnotation {
			needsUpdate = true
		}

		// Only update if something actually changed - this prevents unnecessary ResourceVersion changes
		if !needsUpdate {
			// RoleBinding is already up-to-date, no update needed
			return true, nil
		}

		// Update existing RoleBinding - OVERRIDE any manual changes
		// This ensures consistency and predictability in production environments
		existing.Subjects = roleBinding.Subjects
		existing.RoleRef = roleBinding.RoleRef

		// ADOPTION LOGIC: Remove orphaned annotations if present
		// This allows automatic recovery when PermissionBinder is recreated
		if hasOrphanedAnnotation {
			delete(existing.Annotations, AnnotationOrphanedAt)
			delete(existing.Annotations, AnnotationOrphanedBy)

			// Increment adoption metrics (automatic recovery)
			adoptionEventsTotal.Inc()

			logger.Info("Adopted orphaned RoleBinding - removed orphaned annotations",
				"namespace", namespace,
				"roleBinding", name,
				"permissionBinder", permissionBinder.Name,
				"action", "adoption",
				"recovery", "automatic")
		}

		existing.Annotations[AnnotationManagedBy] = ManagedByValue
		existing.Annotations[AnnotationPermissionBinder] = permissionBinder.Name
		existing.Annotations[AnnotationPermissionBinderNamespace] = permissionBinder.Namespace
		existing.Annotations[AnnotationRole] = role // Store full role name to support roles with hyphens (e.g., "read-only")
		if existing.Annotations[AnnotationCreatedAt] == "" {
			existing.Annotations[AnnotationCreatedAt] = now
		}
		existing.Labels[LabelManagedBy] = ManagedByValue

		if err := r.Update(ctx, &existing); err != nil {
			return false, fmt.Errorf("failed to update RoleBinding %s/%s: %w", namespace, name, err)
		}
	}

	return true, nil
}
