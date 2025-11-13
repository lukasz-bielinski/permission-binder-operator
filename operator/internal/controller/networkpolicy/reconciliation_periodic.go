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
	"context"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/log"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// PeriodicNetworkPolicyReconciliation performs periodic drift detection and reconciliation.
//
// This function checks for configuration drift between the Git repository and the
// Kubernetes cluster. It processes all namespaces with "pr-merged" status in batches
// to detect and report any differences.
//
// The function:
//   - Processes namespaces in batches (20 per batch, 30s sleep between batches)
//   - Detects drift using checkDriftForNamespace
//   - Updates the LastNetworkPolicyReconciliation timestamp in status
//   - Handles template changes detection
//
// This should be called periodically (e.g., every hour) as configured in
// permissionBinder.Spec.NetworkPolicy.ReconciliationInterval.
//
// Parameters:
//   - ctx: Context for cancellation and timeout
//   - r: ReconcilerInterface for Kubernetes API access
//   - permissionBinder: The PermissionBinder CR containing configuration
//
// Returns:
//   - error: Returns an error if reconciliation fails, nil on success
//
// Example:
//
//	err := PeriodicNetworkPolicyReconciliation(ctx, reconciler, binder)
//	if err != nil {
//	    logger.Error(err, "Periodic reconciliation failed")
//	}
func PeriodicNetworkPolicyReconciliation(
	ctx context.Context,
	r ReconcilerInterface,
	permissionBinder *permissionv1.PermissionBinder,
) error {
	logger := log.FromContext(ctx)

	// Get all managed namespaces from status
	managedNamespaces := make([]string, 0)
	for _, status := range permissionBinder.Status.NetworkPolicies {
		if status.State == "pr-merged" {
			managedNamespaces = append(managedNamespaces, status.Namespace)
		}
	}

	if len(managedNamespaces) == 0 {
		logger.Info("No managed namespaces for periodic reconciliation, updating last reconciliation time")
		// Still update last reconciliation time even if no managed namespaces
		now := metav1.Now()
		permissionBinder.Status.LastNetworkPolicyReconciliation = &now
		if err := r.Status().Update(ctx, permissionBinder); err != nil {
			logger.Error(err, "Failed to update last reconciliation time")
			return err
		}
		logger.Info("Successfully updated last reconciliation time", "time", now.Time.Format(time.RFC3339))
		return nil
	}

	// Batch processing for drift detection (20 namespaces per batch, 30s sleep)
	batchSize := 20
	batches := chunkNamespaces(managedNamespaces, batchSize)

	for i, batch := range batches {
		logger.Info("Processing drift detection batch",
			"batch", i+1,
			"totalBatches", len(batches),
			"batchSize", len(batch))

		for _, namespace := range batch {
			if err := checkDriftForNamespace(r, ctx, permissionBinder, namespace); err != nil {
				logger.Error(err, "Failed to check drift", "namespace", namespace)
				// Continue with other namespaces
			}
		}

		// Sleep between batches (to avoid overwhelming etcd)
		if i < len(batches)-1 {
			time.Sleep(30 * time.Second)
		}
	}

	// Check for template changes (simplified - just reprocess all managed namespaces)
	if err := checkTemplateChanges(r, ctx, permissionBinder); err != nil {
		logger.Error(err, "Failed to check template changes")
	}

	// Check stale PRs
	if err := checkStalePRs(r, ctx, permissionBinder); err != nil {
		logger.Error(err, "Failed to check stale PRs")
	}

	// Update last reconciliation time
	now := metav1.Now()
	permissionBinder.Status.LastNetworkPolicyReconciliation = &now
	if err := r.Status().Update(ctx, permissionBinder); err != nil {
		logger.Error(err, "Failed to update last reconciliation time")
		return err
	}
	logger.Info("Successfully updated last reconciliation time", "time", now.Time.Format(time.RFC3339), "managedNamespaces", len(managedNamespaces))

	return nil
}

// checkTemplateChanges checks if templates have changed and triggers PRs for all managed namespaces.
// Simplified: just reprocess all managed namespaces - ProcessNetworkPolicyForNamespace will check if files exist.
func checkTemplateChanges(r ReconcilerInterface, ctx context.Context, permissionBinder *permissionv1.PermissionBinder) error {
	logger := log.FromContext(ctx)

	// Get all managed namespaces
	managedNamespaces := make([]string, 0)
	for _, status := range permissionBinder.Status.NetworkPolicies {
		if status.State == "pr-merged" {
			managedNamespaces = append(managedNamespaces, status.Namespace)
		}
	}

	if len(managedNamespaces) == 0 {
		return nil
	}

	logger.Info("Checking template changes for managed namespaces", "count", len(managedNamespaces))

	// Reprocess all managed namespaces - ProcessNetworkPolicyForNamespace will skip if files already exist
	return ProcessNetworkPoliciesForNamespaces(ctx, r, permissionBinder, managedNamespaces)
}

