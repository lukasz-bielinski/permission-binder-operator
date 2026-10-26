package controller

import (
	"context"
	"fmt"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	"github.com/permission-binder-operator/operator/internal/metadata"
)

const (
	// Annotation keys specific to the ServiceAccount flow - see
	// internal/metadata for the contract (AnnotationCreatedBy is the legacy
	// spelling of AnnotationManagedBy, still written because every SA in the
	// field carries it).
	AnnotationCreatedBy      = metadata.AnnotationCreatedBy
	AnnotationSAType         = metadata.AnnotationSAType
	AnnotationServiceAccount = metadata.AnnotationServiceAccount
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

// stampExistingServiceAccount reconciles the managed-resource stamp on a
// ServiceAccount that already exists - whether it was found by the initial Get
// or by the re-read after a Create lost to it (adoption through a stale cache
// is still adoption, and an adopted object has to end up carrying the same
// annotations and labels as a freshly created one).
//
// Metadata only: the ServiceAccount's spec (secrets, imagePullSecrets) is left
// to whoever manages the workload. Gated on canTakeOwnership, so a
// ServiceAccount claimed by another PermissionBinder is only reported, never
// written to. Failures are non-fatal - the stamp grants no permissions, and
// the next pass retries it - unlike the RoleBinding re-stamp below, which
// establishes the takeover protection itself.
func stampExistingServiceAccount(
	ctx context.Context,
	k8sClient client.Client,
	serviceAccount *corev1.ServiceAccount,
	stamp metadata.Stamp,
	ownerName string,
	ownerNamespace string,
) {
	logger := log.FromContext(ctx)

	if !canTakeOwnership(serviceAccount.Annotations, ownerName, ownerNamespace) {
		logger.Info("Existing ServiceAccount is claimed by another PermissionBinder - treating as satisfied without taking ownership",
			"name", serviceAccount.Name,
			"namespace", serviceAccount.Namespace,
			"claimedBy", serviceAccount.Annotations[AnnotationPermissionBinder],
			"claimedByNamespace", serviceAccount.Annotations[AnnotationPermissionBinderNamespace],
			"reconciledBy", ownerName,
			"reconciledByNamespace", ownerNamespace)
		return
	}

	// An orphaned ServiceAccount being picked up again is an adoption, exactly
	// as for namespaces and group RoleBindings.
	adopted := metadata.ClearOrphan(serviceAccount)
	if adopted {
		adoptionEventsTotal.Inc()
	}
	if !metadata.Apply(serviceAccount, stamp, time.Now()) && !adopted {
		return
	}

	if err := k8sClient.Update(ctx, serviceAccount); err != nil {
		logger.Error(err, "Failed to reconcile the stamp on an existing ServiceAccount (non-fatal, retried next pass)",
			"name", serviceAccount.Name,
			"namespace", serviceAccount.Namespace)
		return
	}
	logger.Info("Reconciled the stamp on an existing ServiceAccount",
		"name", serviceAccount.Name,
		"namespace", serviceAccount.Namespace,
		"adopted", adopted)
}

// stampExistingRoleBinding reconciles the managed-resource stamp on an
// existing ServiceAccount RoleBinding - found by the initial Get, or by the
// re-read after a Create lost to it. Metadata only: RoleRef and Subjects are
// handled by the caller, which has to delete+recreate for an immutable
// RoleRef.
//
// A failure IS fatal here, unlike on the ServiceAccount: these annotations are
// the namespace-aware takeover protection (issue #43), so a RoleBinding that
// silently keeps a stale owner stamp is a security-relevant state, not
// bookkeeping.
//
// The ownership conflict metric is deliberately not incremented here - the
// caller's own gate owns that counter and the matching "skip this SA
// entirely" semantics; this function is reached with the gate already passed,
// except on the stale-cache adoption path where it is the only gate.
func stampExistingRoleBinding(
	ctx context.Context,
	k8sClient client.Client,
	roleBinding *rbacv1.RoleBinding,
	stamp metadata.Stamp,
	ownerName string,
	ownerNamespace string,
) error {
	logger := log.FromContext(ctx)

	if !canTakeOwnership(roleBinding.Annotations, ownerName, ownerNamespace) {
		logger.Info("Refusing to re-stamp a ServiceAccount RoleBinding claimed by another PermissionBinder",
			"roleBinding", roleBinding.Name,
			"namespace", roleBinding.Namespace,
			"claimedBy", roleBinding.Annotations[AnnotationPermissionBinder],
			"claimedByNamespace", roleBinding.Annotations[AnnotationPermissionBinderNamespace],
			"reconciledBy", ownerName,
			"reconciledByNamespace", ownerNamespace)
		return nil
	}

	adopted := metadata.ClearOrphan(roleBinding)
	if adopted {
		adoptionEventsTotal.Inc()
	}
	if !metadata.Apply(roleBinding, stamp, time.Now()) && !adopted {
		return nil
	}

	if err := k8sClient.Update(ctx, roleBinding); err != nil {
		logger.Error(err, "Failed to reconcile the stamp on a ServiceAccount RoleBinding",
			"roleBinding", roleBinding.Name,
			"namespace", roleBinding.Namespace)
		return err
	}
	logger.Info("Reconciled the stamp on an existing ServiceAccount RoleBinding",
		"roleBinding", roleBinding.Name,
		"namespace", roleBinding.Namespace,
		"adopted", adopted)
	return nil
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
		saStamp := serviceAccountStamp(ownerName, ownerNamespace, saName, roleName)

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
						Name:        fullSAName,
						Namespace:   namespace,
						Labels:      saStamp.Labels(),
						Annotations: saStamp.Annotations(time.Now()),
					},
				}

				if err := k8sClient.Create(ctx, newSA); err != nil {
					// AlreadyExists means the cached Get above was stale (informer
					// lag) - the ServiceAccount is present server-side, which is
					// all this step guarantees. Treat as the idempotent
					// already-exists case instead of aborting the namespace.
					if !errors.IsAlreadyExists(err) {
						logger.Error(err, "Failed to create ServiceAccount",
							"name", fullSAName,
							"namespace", namespace)
						return processedSAs, err
					}
					// A create that loses to an existing object IS an adoption:
					// re-read it and reconcile the stamp, instead of leaving a
					// managed ServiceAccount unlabelled until something else
					// happens to touch it. A re-read that is still stale is
					// logged and left for the next pass.
					logger.Info("ServiceAccount already exists (stale cache read), re-reading to reconcile its stamp",
						"name", fullSAName,
						"namespace", namespace)
					if getErr := k8sClient.Get(ctx, saKey, sa); getErr != nil {
						logger.Error(getErr, "Failed to re-read ServiceAccount after AlreadyExists (non-fatal, retried next pass)",
							"name", fullSAName,
							"namespace", namespace)
					} else {
						stampExistingServiceAccount(ctx, k8sClient, sa, saStamp, ownerName, ownerNamespace)
					}
				} else {
					logger.Info("ServiceAccount created successfully",
						"name", fullSAName,
						"namespace", namespace)

					// Increment metric
					serviceAccountsCreated.WithLabelValues(namespace, saName).Inc()
				}
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
			stampExistingServiceAccount(ctx, k8sClient, sa, saStamp, ownerName, ownerNamespace)
		}

		// 2. Create or update RoleBinding for ServiceAccount
		// Use SA key (e.g. "deploy") in name, not ClusterRole name (e.g. "edit")
		// This matches the convention for LDAP group RoleBindings: namespace-role
		roleBindingName := fmt.Sprintf("sa-%s-%s", namespace, saName)
		rbStamp := serviceAccountRoleBindingStamp(ownerName, ownerNamespace, saName, fullSAName)
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
						Name:        roleBindingName,
						Namespace:   namespace,
						Labels:      rbStamp.Labels(),
						Annotations: rbStamp.Annotations(time.Now()),
					},
					RoleRef: rbacv1.RoleRef{
						APIGroup: rbacAPIGroup,
						Kind:     clusterRoleKind,
						Name:     roleName,
					},
					Subjects: []rbacv1.Subject{
						{
							Kind:      serviceAccountKind,
							Name:      fullSAName,
							Namespace: namespace,
						},
					},
				}

				if err := k8sClient.Create(ctx, newRB); err != nil {
					// AlreadyExists = stale cached Get (informer lag); the
					// RoleBinding is present server-side. Almost always it is our
					// own object from a previous reconcile pass - the next pass
					// takes the exists-branch and applies the full ownership
					// gate, so a foreign claim is still refused there.
					if !errors.IsAlreadyExists(err) {
						logger.Error(err, "Failed to create RoleBinding for ServiceAccount",
							"roleBinding", roleBindingName,
							"serviceAccount", fullSAName,
							"namespace", namespace)
						return processedSAs, err
					}
					// A create that loses to an existing object is an adoption:
					// re-read it and reconcile the stamp here, rather than
					// waiting for a later pass to notice. The ownership gate
					// inside stampExistingRoleBinding still refuses a foreign
					// claim.
					logger.Info("RoleBinding for ServiceAccount already exists (stale cache read), re-reading to reconcile its stamp",
						"roleBinding", roleBindingName,
						"serviceAccount", fullSAName,
						"namespace", namespace)
					if getErr := k8sClient.Get(ctx, rbKey, rb); getErr != nil {
						logger.Error(getErr, "Failed to re-read RoleBinding after AlreadyExists (non-fatal, retried next pass)",
							"roleBinding", roleBindingName,
							"namespace", namespace)
					} else if stampErr := stampExistingRoleBinding(ctx, k8sClient, rb, rbStamp, ownerName, ownerNamespace); stampErr != nil {
						return processedSAs, stampErr
					}
				} else {
					logger.Info("RoleBinding created successfully for ServiceAccount",
						"roleBinding", roleBindingName,
						"serviceAccount", fullSAName,
						"role", roleName,
						"namespace", namespace)
				}

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
			// flapping when the mapping later changes). Only unclaimed, own
			// and legacy name-only RoleBindings are manageable here. Since SA
			// RoleBindings carry LabelManagedBy they are now in scope for
			// SAFE-MODE orphan annotation on CR deletion, like group ones.
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
			// upgrade asymmetry). Metadata-only changes use a plain Update -
			// delete+recreate would briefly drop the granted permissions - so
			// the stamp is reconciled only when the spec itself is fine; when
			// it is not, the recreate below writes the current stamp anyway.
			if !needsUpdate {
				if err := stampExistingRoleBinding(ctx, k8sClient, rb, rbStamp, ownerName, ownerNamespace); err != nil {
					return processedSAs, err
				}
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
						Name:        roleBindingName,
						Namespace:   namespace,
						Labels:      rbStamp.Labels(),
						Annotations: rbStamp.Annotations(time.Now()),
					},
					RoleRef: rbacv1.RoleRef{
						APIGroup: rbacAPIGroup,
						Kind:     clusterRoleKind,
						Name:     roleName,
					},
					Subjects: []rbacv1.Subject{
						{
							Kind:      serviceAccountKind,
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
