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
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
	networkpolicy "github.com/permission-binder-operator/operator/internal/controller/networkpolicy"
)

const (
	// Annotation keys
	AnnotationManagedBy        = "permission-binder.io/managed-by"
	AnnotationCreatedAt        = "permission-binder.io/created-at"
	AnnotationPermissionBinder = "permission-binder.io/permission-binder"
	AnnotationRole             = "permission-binder.io/role"

	// Label keys
	LabelManagedBy = "permission-binder.io/managed-by"

	// Values
	ManagedByValue = "permission-binder-operator"

	// Finalizer
	PermissionBinderFinalizer = "permission-binder.io/finalizer"
)

// PermissionBinderReconciler reconciles a PermissionBinder object
type PermissionBinderReconciler struct {
	client.Client
	Scheme    *runtime.Scheme
	DebugMode bool
}

// Status returns the StatusWriter for updating subresource status
func (r *PermissionBinderReconciler) Status() client.StatusWriter {
	return r.Client.Status()
}

// +kubebuilder:rbac:groups=permission.permission-binder.io,resources=permissionbinders,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=permission.permission-binder.io,resources=permissionbinders/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=permission.permission-binder.io,resources=permissionbinders/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=configmaps,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=namespaces,verbs=get;list;watch;create
// +kubebuilder:rbac:groups="",resources=serviceaccounts,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=rbac.authorization.k8s.io,resources=rolebindings,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=rbac.authorization.k8s.io,resources=clusterroles,verbs=get;list;watch

// Reconcile is part of the main kubernetes reconciliation loop which aims to
// move the current state of the cluster closer to the desired state.
//
// For more details, check Reconcile and its Result here:
// - https://pkg.go.dev/sigs.k8s.io/controller-runtime@v0.19.0/pkg/reconcile
func (r *PermissionBinderReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// Log reconciliation trigger in debug mode
	if r.DebugMode {
		logger.Info("🔍 DEBUG: Reconciliation triggered",
			"trigger", "Reconcile",
			"request", req.NamespacedName,
			"timestamp", time.Now().Format(time.RFC3339Nano))
	}

	// Fetch the PermissionBinder instance
	var permissionBinder permissionv1.PermissionBinder
	if err := r.Get(ctx, req.NamespacedName, &permissionBinder); err != nil {
		if errors.IsNotFound(err) {
			if r.DebugMode {
				logger.Info("🔍 DEBUG: PermissionBinder not found (deleted)", "request", req.NamespacedName)
			}
			logger.Info("PermissionBinder resource not found. Ignoring since object must be deleted")
			return ctrl.Result{}, nil
		}
		logger.Error(err, "Failed to get PermissionBinder")
		return ctrl.Result{}, err
	}

	if r.DebugMode {
		logger.Info("🔍 DEBUG: PermissionBinder fetched",
			"generation", permissionBinder.Generation,
			"resourceVersion", permissionBinder.ResourceVersion,
			"hasDeletionTimestamp", !permissionBinder.DeletionTimestamp.IsZero(),
			"finalizers", permissionBinder.Finalizers)
	}

	// Check if this is a deletion - clean up managed resources
	if !permissionBinder.DeletionTimestamp.IsZero() {
		// The object is being deleted
		if containsString(permissionBinder.Finalizers, PermissionBinderFinalizer) {
			// Run finalization logic
			logger.Info("PermissionBinder is being deleted, cleaning up managed resources")
			if err := r.cleanupManagedResources(ctx, &permissionBinder); err != nil {
				logger.Error(err, "Failed to cleanup managed resources")
				return ctrl.Result{}, err
			}

			// Remove finalizer to allow deletion
			permissionBinder.Finalizers = removeString(permissionBinder.Finalizers, PermissionBinderFinalizer)
			if err := r.Update(ctx, &permissionBinder); err != nil {
				logger.Error(err, "Failed to remove finalizer")
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, nil
	}

	// Add finalizer if not present
	if !containsString(permissionBinder.Finalizers, PermissionBinderFinalizer) {
		permissionBinder.Finalizers = append(permissionBinder.Finalizers, PermissionBinderFinalizer)
		if err := r.Update(ctx, &permissionBinder); err != nil {
			logger.Error(err, "Failed to add finalizer")
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	// Check if role mapping has changed
	roleMappingChanged, currentHash := r.hasRoleMappingChanged(&permissionBinder)
	if r.DebugMode {
		logger.Info("🔍 DEBUG: Role mapping check",
			"changed", roleMappingChanged,
			"currentHash", currentHash,
			"lastProcessedHash", permissionBinder.Status.LastProcessedRoleMappingHash,
			"isFirstTime", permissionBinder.Status.LastProcessedRoleMappingHash == "")
	}
	if roleMappingChanged {
		logger.Info("Role mapping has changed, reconciling all managed resources",
			"currentHash", currentHash,
			"previousHash", permissionBinder.Status.LastProcessedRoleMappingHash)
		if err := r.reconcileAllManagedResources(ctx, &permissionBinder); err != nil {
			logger.Error(err, "Failed to reconcile all managed resources")
			return ctrl.Result{}, err
		}
		// Note: We don't update status here to avoid multiple Status().Update() calls
		// The hash will be updated in the final status update at the end of reconciliation
		// The predicate will filter out status-only updates, so this won't cause loops
	}

	// Re-fetch PermissionBinder to ensure we have the latest excludeList and status
	// This prevents race conditions when excludeList and ConfigMap are updated concurrently
	if err := r.Get(ctx, req.NamespacedName, &permissionBinder); err != nil {
		logger.Error(err, "Failed to re-fetch PermissionBinder")
		return ctrl.Result{}, err
	}

	if r.DebugMode {
		logger.Info("🔍 DEBUG: PermissionBinder re-fetched",
			"generation", permissionBinder.Generation,
			"resourceVersion", permissionBinder.ResourceVersion,
			"lastProcessedRoleMappingHash", permissionBinder.Status.LastProcessedRoleMappingHash,
			"lastProcessedConfigMapVersion", permissionBinder.Status.LastProcessedConfigMapVersion)
	}

	// Fetch the ConfigMap
	var configMap corev1.ConfigMap
	configMapKey := types.NamespacedName{
		Name:      permissionBinder.Spec.ConfigMapName,
		Namespace: permissionBinder.Spec.ConfigMapNamespace,
	}
	if err := r.Get(ctx, configMapKey, &configMap); err != nil {
		if errors.IsNotFound(err) {
			logger.Info("ConfigMap not found", "configMap", configMapKey)
			return ctrl.Result{RequeueAfter: time.Minute}, nil
		}
		logger.Error(err, "Failed to get ConfigMap", "configMap", configMapKey)
		return ctrl.Result{}, err
	}

	// Check if ConfigMap has changed
	configMapVersion := configMap.ResourceVersion

	// Re-check role mapping hash after re-fetch (in case it was updated)
	// This ensures we don't incorrectly think role mapping changed when it didn't
	roleMappingChangedAfterRefetch, currentHashAfterRefetch := r.hasRoleMappingChanged(&permissionBinder)
	if roleMappingChanged && !roleMappingChangedAfterRefetch {
		// Hash was just updated, so now it should match
		if r.DebugMode {
			logger.Info("🔍 DEBUG: Role mapping hash was updated, re-checking",
				"previousCheck", roleMappingChanged,
				"afterRefetch", roleMappingChangedAfterRefetch,
				"currentHash", currentHashAfterRefetch,
				"lastHashAfterRefetch", permissionBinder.Status.LastProcessedRoleMappingHash)
		}
		roleMappingChanged = false
		currentHash = currentHashAfterRefetch
	}

	if r.DebugMode {
		logger.Info("🔍 DEBUG: ConfigMap version check",
			"currentVersion", configMapVersion,
			"lastProcessedVersion", permissionBinder.Status.LastProcessedConfigMapVersion,
			"roleMappingChanged", roleMappingChanged,
			"roleMappingChangedAfterRefetch", roleMappingChangedAfterRefetch,
			"skipReconciliation", permissionBinder.Status.LastProcessedConfigMapVersion == configMapVersion && !roleMappingChanged)
	}
	if permissionBinder.Status.LastProcessedConfigMapVersion == configMapVersion && !roleMappingChanged {
		if r.DebugMode {
			logger.Info("🔍 DEBUG: Skipping reconciliation - no changes detected",
				"configMapVersion", configMapVersion,
				"roleMappingChanged", roleMappingChanged)
		}
		logger.Info("ConfigMap and role mapping have not changed, skipping reconciliation")
		return ctrl.Result{}, nil
	}

	if r.DebugMode {
		reason := "Role mapping changed"
		if permissionBinder.Status.LastProcessedConfigMapVersion != configMapVersion {
			reason = "ConfigMap version changed"
		}
		logger.Info("🔍 DEBUG: Processing ConfigMap",
			"reason", reason,
			"configMapVersion", configMapVersion,
			"configMapName", configMap.Name,
			"configMapNamespace", configMap.Namespace)
	}

	// Process ConfigMap data
	result, err := r.processConfigMap(ctx, &permissionBinder, &configMap)
	if err != nil {
		logger.Error(err, "Failed to process ConfigMap")
		return ctrl.Result{}, err
	}

	// Process NetworkPolicies if enabled
	if permissionBinder.Spec.NetworkPolicy != nil && permissionBinder.Spec.NetworkPolicy.Enabled {
		// Check for multiple PermissionBinder CRs with NetworkPolicy enabled
		if err := networkpolicy.CheckMultiplePermissionBinders(ctx, r); err != nil {
			logger.Error(err, "Failed to check multiple PermissionBinders (non-fatal)")
			// Continue - not blocking
		}

		// Extract namespaces from processed RoleBindings
		namespaces := make(map[string]bool)
		for _, rb := range result.ProcessedRoleBindings {
			// RoleBinding format: "namespace/rolebinding-name"
			parts := strings.Split(rb, "/")
			if len(parts) == 2 {
				namespaces[parts[0]] = true
			}
		}

		// Convert to slice
		namespaceList := make([]string, 0, len(namespaces))
		for ns := range namespaces {
			// Check global exclude list
			if networkpolicy.IsNamespaceExcluded(ns, permissionBinder.Spec.NetworkPolicy.ExcludeNamespaces) {
				logger.V(1).Info("Skipping namespace - excluded from NetworkPolicy operations",
					"namespace", ns)
				continue
			}
			namespaceList = append(namespaceList, ns)
		}

		// Event-driven reconciliation: Process new/changed namespaces
		if len(namespaceList) > 0 {
			logger.Info("Processing NetworkPolicies for namespaces (event-driven)",
				"count", len(namespaceList))
			if err := networkpolicy.ProcessNetworkPoliciesForNamespaces(ctx, r, &permissionBinder, namespaceList); err != nil {
				logger.Error(err, "Failed to process NetworkPolicies (non-fatal)")
				// Continue - don't fail reconciliation
			}
		}

		// Process removed namespaces (check for namespaces that were removed from whitelist)
		if err := networkpolicy.ProcessRemovedNamespaces(ctx, r, &permissionBinder, namespaces); err != nil {
			logger.Error(err, "Failed to process removed namespaces (non-fatal)")
			// Continue - don't fail reconciliation
		}

		// Periodic reconciliation: Check if it's time for periodic reconciliation
		shouldRunPeriodic := false
		if permissionBinder.Status.LastNetworkPolicyReconciliation == nil {
			// First time - run periodic reconciliation
			shouldRunPeriodic = true
		} else {
			// Check if reconciliation interval has passed
			intervalStr := permissionBinder.Spec.NetworkPolicy.ReconciliationInterval
			if intervalStr == "" {
				intervalStr = "1h"
			}
			interval, err := time.ParseDuration(intervalStr)
			if err != nil {
				// Default to 1h if parsing fails
				interval = 1 * time.Hour
			}

			lastReconciliation := permissionBinder.Status.LastNetworkPolicyReconciliation.Time
			if time.Since(lastReconciliation) >= interval {
				shouldRunPeriodic = true
			}
		}

		if shouldRunPeriodic {
			logger.Info("Running periodic NetworkPolicy reconciliation")
			if err := networkpolicy.PeriodicNetworkPolicyReconciliation(ctx, r, &permissionBinder); err != nil {
				logger.Error(err, "Failed to run periodic NetworkPolicy reconciliation (non-fatal)")
				// Continue - don't fail reconciliation
			}
		}

		// Cleanup status (remove old entries after retention period)
		if err := networkpolicy.CleanupStatus(ctx, r, &permissionBinder, namespaces); err != nil {
			logger.Error(err, "Failed to cleanup NetworkPolicy status (non-fatal)")
			// Continue - don't fail reconciliation
		}
	}

	// Prepare new status values
	newProcessedRoleBindings := result.ProcessedRoleBindings
	newProcessedServiceAccounts := result.ProcessedServiceAccounts
	newConfigMapVersion := configMapVersion
	newRoleMappingHash := permissionBinder.Status.LastProcessedRoleMappingHash
	if roleMappingChanged {
		newRoleMappingHash = currentHash
	}

	// Check if status actually changed before updating
	// This prevents unnecessary ResourceVersion changes
	statusChanged := false

	// Compare ProcessedRoleBindings
	if !reflect.DeepEqual(permissionBinder.Status.ProcessedRoleBindings, newProcessedRoleBindings) {
		statusChanged = true
	}

	// Compare ProcessedServiceAccounts
	if !reflect.DeepEqual(permissionBinder.Status.ProcessedServiceAccounts, newProcessedServiceAccounts) {
		statusChanged = true
	}

	// Compare ConfigMap version
	if permissionBinder.Status.LastProcessedConfigMapVersion != newConfigMapVersion {
		statusChanged = true
	}

	// Compare role mapping hash
	if permissionBinder.Status.LastProcessedRoleMappingHash != newRoleMappingHash {
		statusChanged = true
	}

	// Check if Conditions need update (only update LastTransitionTime if status changed)
	conditionMessage := fmt.Sprintf("Successfully processed %d role bindings and %d service accounts", len(newProcessedRoleBindings), len(newProcessedServiceAccounts))
	existingCondition := findCondition(permissionBinder.Status.Conditions, "Processed")
	if existingCondition == nil || existingCondition.Status != metav1.ConditionTrue || existingCondition.Message != conditionMessage {
		statusChanged = true
	}

	// Only update status if something actually changed
	if !statusChanged {
		if r.DebugMode {
			logger.Info("🔍 DEBUG: Status unchanged, skipping status update",
				"configMapVersion", configMapVersion,
				"roleBindingsCount", len(newProcessedRoleBindings),
				"serviceAccountsCount", len(newProcessedServiceAccounts))
		}
		logger.Info("Status unchanged, skipping status update")
	} else {
		// Update status - do this in a single update to avoid multiple ResourceVersion changes
		permissionBinder.Status.ProcessedRoleBindings = newProcessedRoleBindings
		permissionBinder.Status.ProcessedServiceAccounts = newProcessedServiceAccounts
		permissionBinder.Status.LastProcessedConfigMapVersion = newConfigMapVersion
		permissionBinder.Status.LastProcessedRoleMappingHash = newRoleMappingHash

		// Update Conditions - preserve LastTransitionTime if condition already exists with same status
		now := metav1.Now()
		if existingCondition != nil && existingCondition.Status == metav1.ConditionTrue && existingCondition.Message == conditionMessage {
			// Condition already exists with same status, preserve LastTransitionTime
			permissionBinder.Status.Conditions = []metav1.Condition{
				{
					Type:               "Processed",
					Status:             metav1.ConditionTrue,
					LastTransitionTime: existingCondition.LastTransitionTime, // Preserve original time
					Reason:             "ConfigMapProcessed",
					Message:            conditionMessage,
					ObservedGeneration: permissionBinder.Generation,
				},
			}
		} else {
			// New condition or status changed, use current time
			permissionBinder.Status.Conditions = []metav1.Condition{
				{
					Type:               "Processed",
					Status:             metav1.ConditionTrue,
					LastTransitionTime: now,
					Reason:             "ConfigMapProcessed",
					Message:            conditionMessage,
					ObservedGeneration: permissionBinder.Generation,
				},
			}
		}

		if err := r.Status().Update(ctx, &permissionBinder); err != nil {
			logger.Error(err, "Failed to update PermissionBinder status")
			return ctrl.Result{}, err
		}

		if r.DebugMode {
			logger.Info("🔍 DEBUG: Status updated",
				"configMapVersion", configMapVersion,
				"roleBindingsCount", len(newProcessedRoleBindings),
				"serviceAccountsCount", len(newProcessedServiceAccounts),
				"roleMappingHashChanged", roleMappingChanged)
		}
	}

	// Update Prometheus metrics for monitoring
	if err := r.updateMetrics(ctx, &permissionBinder); err != nil {
		logger.Error(err, "Failed to update metrics (non-fatal)")
		// Don't fail reconciliation on metrics error
	}

	logger.Info("Successfully processed ConfigMap",
		"roleBindings", len(result.ProcessedRoleBindings),
		"serviceAccounts", len(result.ProcessedServiceAccounts))
	return ctrl.Result{}, nil
}

