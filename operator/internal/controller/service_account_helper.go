package controller

import (
	"context"
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

const (
	// Annotation keys specific to the ServiceAccount flow.
	AnnotationCreatedBy      = "permission-binder.io/created-by"
	AnnotationSAType         = "permission-binder.io/sa-type"
	AnnotationServiceAccount = "permission-binder.io/service-account"
)

// GenerateServiceAccountName generates a ServiceAccount name based on the pattern
// Available variables: {namespace}, {name}
// Default pattern: {namespace}-sa-{name}
func GenerateServiceAccountName(pattern, namespace, name string) string {
	// If pattern is empty, use default
	if pattern == "" {
		pattern = "{namespace}-sa-{name}"
	}

	// Replace variables
	result := pattern
	result = strings.ReplaceAll(result, "{namespace}", namespace)
	result = strings.ReplaceAll(result, "{name}", name)

	return result
}

// ProcessServiceAccounts creates ServiceAccounts and RoleBindings for a namespace
// based on the ServiceAccountMapping configuration
// ownerName and ownerNamespace identify the owning PermissionBinder CR; they are
// stamped on the created resources so ownership is unique per operator instance.
func ProcessServiceAccounts(
	ctx context.Context,
	k8sClient client.Client,
	namespace string,
	saMapping map[string]string,
	namingPattern string,
	ownerName string,
	ownerNamespace string,
) ([]string, error) {
	logger := log.FromContext(ctx)
	processedSAs := []string{}

	if len(saMapping) == 0 {
		logger.Info("No ServiceAccount mappings configured, skipping SA creation")
		return processedSAs, nil
	}

	logger.Info("Processing ServiceAccount mappings",
		"namespace", namespace,
		"mappings", len(saMapping))

	for saName, roleName := range saMapping {
		// Generate SA name using pattern
		fullSAName := GenerateServiceAccountName(namingPattern, namespace, saName)

		// 1. Create or verify ServiceAccount exists
		sa := &corev1.ServiceAccount{}
		saKey := types.NamespacedName{
			Name:      fullSAName,
			Namespace: namespace,
		}

		err := k8sClient.Get(ctx, saKey, sa)
		if err != nil {
			if errors.IsNotFound(err) {
				// ServiceAccount doesn't exist, create it
				logger.Info("Creating ServiceAccount",
					"name", fullSAName,
					"namespace", namespace)

				newSA := &corev1.ServiceAccount{
					ObjectMeta: metav1.ObjectMeta{
						Name:      fullSAName,
						Namespace: namespace,
						Labels: map[string]string{
							"app.kubernetes.io/managed-by": ManagedByValue,
							"app.kubernetes.io/component":  saName, // deploy, runtime, etc.
							"app.kubernetes.io/name":       ownerName,
						},
						Annotations: map[string]string{
							AnnotationCreatedBy:                 ManagedByValue,
							AnnotationSAType:                    saName,
							AnnotationRole:                      roleName,
							AnnotationPermissionBinder:          ownerName,
							AnnotationPermissionBinderNamespace: ownerNamespace,
						},
					},
				}

				if err := k8sClient.Create(ctx, newSA); err != nil {
					logger.Error(err, "Failed to create ServiceAccount",
						"name", fullSAName,
						"namespace", namespace)
					return processedSAs, err
				}

				logger.Info("ServiceAccount created successfully",
					"name", fullSAName,
					"namespace", namespace)

				// Increment metric
				serviceAccountsCreated.WithLabelValues(namespace, saName).Inc()
			} else {
				logger.Error(err, "Failed to get ServiceAccount",
					"name", fullSAName,
					"namespace", namespace)
				return processedSAs, err
			}
		} else {
			// ServiceAccount already exists, skip (idempotent)
			logger.Info("ServiceAccount already exists, skipping creation",
				"name", fullSAName,
				"namespace", namespace)
			// Visibility only (issue #43): the SA half never mutates existing
			// objects, but flag when a foreign-claimed SA is treated as satisfied.
			if sa.Annotations[AnnotationPermissionBinder] != "" && !isOwnedBy(sa.Annotations, ownerName, ownerNamespace) {
				logger.Info("Existing ServiceAccount is claimed by another PermissionBinder - treating as satisfied without taking ownership",
					"name", fullSAName,
					"namespace", namespace,
					"claimedBy", sa.Annotations[AnnotationPermissionBinder],
					"claimedByNamespace", sa.Annotations[AnnotationPermissionBinderNamespace],
					"reconciledBy", ownerName,
					"reconciledByNamespace", ownerNamespace)
			}
		}

		// 2. Create or update RoleBinding for ServiceAccount
		// Use SA key (e.g. "deploy") in name, not ClusterRole name (e.g. "edit")
		// This matches the convention for LDAP group RoleBindings: namespace-role
		roleBindingName := fmt.Sprintf("sa-%s-%s", namespace, saName)
		rb := &rbacv1.RoleBinding{}
		rbKey := types.NamespacedName{
			Name:      roleBindingName,
			Namespace: namespace,
		}

		err = k8sClient.Get(ctx, rbKey, rb)
		if err != nil {
			if errors.IsNotFound(err) {
				// RoleBinding doesn't exist, create it
				logger.Info("Creating RoleBinding for ServiceAccount",
					"roleBinding", roleBindingName,
					"serviceAccount", fullSAName,
					"role", roleName,
					"namespace", namespace)

				newRB := &rbacv1.RoleBinding{
					ObjectMeta: metav1.ObjectMeta{
						Name:      roleBindingName,
						Namespace: namespace,
						Labels: map[string]string{
							"app.kubernetes.io/managed-by": ManagedByValue,
							"app.kubernetes.io/component":  "service-account-binding",
							"app.kubernetes.io/name":       ownerName,
						},
						Annotations: map[string]string{
							AnnotationCreatedBy:                 ManagedByValue,
							AnnotationServiceAccount:            fullSAName,
							AnnotationSAType:                    saName,
							AnnotationPermissionBinder:          ownerName,
							AnnotationPermissionBinderNamespace: ownerNamespace,
						},
					},
					RoleRef: rbacv1.RoleRef{
						APIGroup: "rbac.authorization.k8s.io",
						Kind:     "ClusterRole",
						Name:     roleName,
					},
					Subjects: []rbacv1.Subject{
						{
							Kind:      "ServiceAccount",
							Name:      fullSAName,
							Namespace: namespace,
						},
					},
				}

				if err := k8sClient.Create(ctx, newRB); err != nil {
					logger.Error(err, "Failed to create RoleBinding for ServiceAccount",
						"roleBinding", roleBindingName,
						"serviceAccount", fullSAName,
						"namespace", namespace)
					return processedSAs, err
				}

				logger.Info("RoleBinding created successfully for ServiceAccount",
					"roleBinding", roleBindingName,
					"serviceAccount", fullSAName,
					"role", roleName,
					"namespace", namespace)

				// Metrics are updated in controller after processing all namespaces
			} else {
				logger.Error(err, "Failed to get RoleBinding",
					"roleBinding", roleBindingName,
					"namespace", namespace)
				return processedSAs, err
			}
		} else {
			// OWNERSHIP GATE (issue #43): a RoleBinding with a live claim by
			// another PermissionBinder is excluded from this CR's processing
			// entirely - not deleted/recreated on drift and not counted in
			// processedSAs/status either (consistent exclusion, no metric
			// flapping when the mapping later changes). SA RoleBindings are
			// never orphan-annotated (SAFE-MODE cleanup selects by
			// LabelManagedBy, which they do not carry), so only unclaimed,
			// own and legacy name-only RoleBindings are manageable here.
			if !canTakeOwnership(rb.Annotations, ownerName, ownerNamespace) {
				ownershipConflictsTotal.WithLabelValues("serviceaccount_rolebinding").Inc()
				logger.Info("Refusing to take ownership of ServiceAccount RoleBinding claimed by another PermissionBinder",
					"roleBinding", roleBindingName,
					"namespace", namespace,
					"claimedBy", rb.Annotations[AnnotationPermissionBinder],
					"claimedByNamespace", rb.Annotations[AnnotationPermissionBinderNamespace],
					"reconciledBy", ownerName,
					"reconciledByNamespace", ownerNamespace)
				continue
			}

			// RoleBinding exists, check if it needs update
			needsUpdate := false

			// Check if RoleRef changed
			if rb.RoleRef.Name != roleName {
				logger.Info("RoleBinding role changed, needs update",
					"roleBinding", roleBindingName,
					"oldRole", rb.RoleRef.Name,
					"newRole", roleName)
				needsUpdate = true
			}

			// Check if Subject changed
			if len(rb.Subjects) == 0 || rb.Subjects[0].Name != fullSAName {
				logger.Info("RoleBinding subject changed, needs update",
					"roleBinding", roleBindingName)
				needsUpdate = true
			}

			// Legacy RoleBindings (name-only or missing ownership annotations)
			// are re-stamped in place on first reconcile, so the
			// namespace-aware takeover protection engages immediately after
			// upgrade instead of only when the role mapping changes (issue #43
			// upgrade asymmetry). Annotation-only changes use a plain Update -
			// delete+recreate would briefly drop the granted permissions.
			stampOutdated := rb.Annotations[AnnotationPermissionBinderNamespace] != ownerNamespace ||
				rb.Annotations[AnnotationPermissionBinder] != ownerName

			if !needsUpdate && stampOutdated {
				if rb.Annotations == nil {
					rb.Annotations = make(map[string]string)
				}
				rb.Annotations[AnnotationPermissionBinder] = ownerName
				rb.Annotations[AnnotationPermissionBinderNamespace] = ownerNamespace
				if err := k8sClient.Update(ctx, rb); err != nil {
					logger.Error(err, "Failed to re-stamp ownership annotations on RoleBinding",
						"roleBinding", roleBindingName,
						"namespace", namespace)
					return processedSAs, err
				}
				logger.Info("Re-stamped ownership annotations on legacy RoleBinding",
					"roleBinding", roleBindingName,
					"namespace", namespace)
			}

			if needsUpdate {
				// Update RoleBinding
				// Note: RoleRef is immutable, so we need to delete and recreate
				logger.Info("Deleting RoleBinding for update",
					"roleBinding", roleBindingName,
					"namespace", namespace)

				if err := k8sClient.Delete(ctx, rb); err != nil {
					logger.Error(err, "Failed to delete RoleBinding for update",
						"roleBinding", roleBindingName)
					return processedSAs, err
				}

				// Recreate with new values
				newRB := &rbacv1.RoleBinding{
					ObjectMeta: metav1.ObjectMeta{
						Name:      roleBindingName,
						Namespace: namespace,
						Labels: map[string]string{
							"app.kubernetes.io/managed-by": ManagedByValue,
							"app.kubernetes.io/component":  "service-account-binding",
							"app.kubernetes.io/name":       ownerName,
						},
						Annotations: map[string]string{
							AnnotationCreatedBy:                 ManagedByValue,
							AnnotationServiceAccount:            fullSAName,
							AnnotationSAType:                    saName,
							AnnotationPermissionBinder:          ownerName,
							AnnotationPermissionBinderNamespace: ownerNamespace,
						},
					},
					RoleRef: rbacv1.RoleRef{
						APIGroup: "rbac.authorization.k8s.io",
						Kind:     "ClusterRole",
						Name:     roleName,
					},
					Subjects: []rbacv1.Subject{
						{
							Kind:      "ServiceAccount",
							Name:      fullSAName,
							Namespace: namespace,
						},
					},
				}

				if err := k8sClient.Create(ctx, newRB); err != nil {
					logger.Error(err, "Failed to recreate RoleBinding",
						"roleBinding", roleBindingName)
					return processedSAs, err
				}

				logger.Info("RoleBinding updated successfully",
					"roleBinding", roleBindingName,
					"namespace", namespace)
			} else {
				logger.Info("RoleBinding already up-to-date",
					"roleBinding", roleBindingName,
					"namespace", namespace)
			}
		}

		// Track processed SA
		processedSAs = append(processedSAs, fmt.Sprintf("%s/%s", namespace, fullSAName))
	}

	logger.Info("ServiceAccount processing completed",
		"namespace", namespace,
		"processed", len(processedSAs))

	return processedSAs, nil
}
