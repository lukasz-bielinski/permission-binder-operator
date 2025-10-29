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
func ProcessServiceAccounts(
	ctx context.Context,
	k8sClient client.Client,
	namespace string,
	saMapping map[string]string,
	namingPattern string,
	ownerName string,
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
							"app.kubernetes.io/managed-by": "permission-binder-operator",
							"app.kubernetes.io/component":  saName, // deploy, runtime, etc.
							"app.kubernetes.io/name":       ownerName,
						},
						Annotations: map[string]string{
							"permission-binder.io/created-by": "permission-binder-operator",
							"permission-binder.io/sa-type":    saName,
							"permission-binder.io/role":       roleName,
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
		}

		// 2. Create or update RoleBinding for ServiceAccount
		roleBindingName := fmt.Sprintf("%s-%s", fullSAName, roleName)
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
							"app.kubernetes.io/managed-by": "permission-binder-operator",
							"app.kubernetes.io/component":  "service-account-binding",
							"app.kubernetes.io/name":       ownerName,
						},
						Annotations: map[string]string{
							"permission-binder.io/created-by":      "permission-binder-operator",
							"permission-binder.io/service-account": fullSAName,
							"permission-binder.io/sa-type":         saName,
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
							"app.kubernetes.io/managed-by": "permission-binder-operator",
							"app.kubernetes.io/component":  "service-account-binding",
							"app.kubernetes.io/name":       ownerName,
						},
						Annotations: map[string]string{
							"permission-binder.io/created-by":      "permission-binder-operator",
							"permission-binder.io/service-account": fullSAName,
							"permission-binder.io/sa-type":         saName,
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
