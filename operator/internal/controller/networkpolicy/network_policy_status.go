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
	"fmt"
	"time"

	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

func getNetworkPolicyStatus(permissionBinder *permissionv1.PermissionBinder, namespace string) *permissionv1.NetworkPolicyStatus {
	for i := range permissionBinder.Status.NetworkPolicies {
		if permissionBinder.Status.NetworkPolicies[i].Namespace == namespace {
			return &permissionBinder.Status.NetworkPolicies[i]
		}
	}
	return nil
}

// hasNetworkPolicyStatus checks if namespace has a status entry
func hasNetworkPolicyStatus(permissionBinder *permissionv1.PermissionBinder, namespace string) bool {
	return getNetworkPolicyStatus(permissionBinder, namespace) != nil
}

// updateNetworkPolicyStatus updates or creates NetworkPolicy status for a namespace
func updateNetworkPolicyStatus(r ReconcilerInterface, 
	ctx context.Context,
	permissionBinder *permissionv1.PermissionBinder,
	namespace string,
	state string,
	errorMessage string,
) error {
	logger := log.FromContext(ctx)

	// Find existing status or create new
	status := getNetworkPolicyStatus(permissionBinder, namespace)
	if status == nil {
		// Create new status entry
		status = &permissionv1.NetworkPolicyStatus{
			Namespace: namespace,
			State:     state,
		}
		permissionBinder.Status.NetworkPolicies = append(permissionBinder.Status.NetworkPolicies, *status)
	} else {
		// Update existing status
		status.State = state
	}

	// Update fields
	if errorMessage != "" {
		status.ErrorMessage = errorMessage
	}

	if state == "pr-created" || state == "pr-pending" {
		if status.CreatedAt == "" {
			status.CreatedAt = time.Now().Format(time.RFC3339)
		}
	}

	// Update status in cluster
	if err := r.Status().Update(ctx, permissionBinder); err != nil {
		logger.Error(err, "Failed to update NetworkPolicy status",
			"namespace", namespace,
			"state", state)
		return fmt.Errorf("failed to update status: %w", err)
	}

	logger.V(1).Info("Updated NetworkPolicy status",
		"namespace", namespace,
		"state", state)

	return nil
}

// updateNetworkPolicyStatusWithPR updates NetworkPolicy status with PR information
// Uses retry logic to handle race conditions with concurrent status updates
func updateNetworkPolicyStatusWithPR(r ReconcilerInterface, 
	ctx context.Context,
	permissionBinder *permissionv1.PermissionBinder,
	namespace string,
	prNumber int,
	prBranch string,
	prURL string,
	state string,
) error {
	logger := log.FromContext(ctx)
	
	// Retry logic to handle race conditions (max 3 attempts)
	maxRetries := 3
	for attempt := 0; attempt < maxRetries; attempt++ {
		// Get fresh copy of PermissionBinder to avoid stale data
		key := client.ObjectKeyFromObject(permissionBinder)
		var freshBinder permissionv1.PermissionBinder
		if err := r.Get(ctx, key, &freshBinder); err != nil {
			if attempt < maxRetries-1 {
				time.Sleep(100 * time.Millisecond)
				continue
			}
			return fmt.Errorf("failed to get fresh PermissionBinder: %w", err)
		}
		
		status := getNetworkPolicyStatus(&freshBinder, namespace)
		if status == nil {
			// Create new status entry
			newStatus := permissionv1.NetworkPolicyStatus{
				Namespace: namespace,
				State:     state,
			}
			freshBinder.Status.NetworkPolicies = append(freshBinder.Status.NetworkPolicies, newStatus)
			// Get pointer to the newly added status
			status = getNetworkPolicyStatus(&freshBinder, namespace)
			if status == nil {
				return fmt.Errorf("failed to get newly created status")
			}
		}

		// Update status fields (preserve existing PR info if updating state only)
		status.State = state
		status.PRNumber = &prNumber
		status.PRBranch = prBranch
		status.PRURL = prURL
		if status.CreatedAt == "" {
			status.CreatedAt = time.Now().Format(time.RFC3339)
		}

		// Update status in cluster
		if err := r.Status().Update(ctx, &freshBinder); err != nil {
			if attempt < maxRetries-1 {
				logger.V(1).Info("Status update conflict, retrying", "attempt", attempt+1, "namespace", namespace)
				time.Sleep(200 * time.Millisecond)
				continue
			}
			logger.Error(err, "Failed to update NetworkPolicy status with PR after retries", "namespace", namespace)
			return fmt.Errorf("failed to update status: %w", err)
		}
		
		// Success - update the passed-in permissionBinder to reflect changes
		*permissionBinder = freshBinder
		return nil
	}
	
	return fmt.Errorf("failed to update status after %d attempts", maxRetries)
}

// CleanupStatus removes old status entries for namespaces that are no longer in the whitelist.
//
// This function implements a retention policy for status entries:
//   - Active namespaces: Always kept (regardless of retention period)
//   - Removed namespaces: Kept for the configured retention period (default: 30 days)
//   - Old removed namespaces: Deleted after retention period expires
//
// The retention period is configured via permissionBinder.Spec.NetworkPolicy.StatusRetentionDays.
// If not configured, the default value (30 days) is used.
//
// Parameters:
//   - ctx: Context for cancellation and timeout
//   - r: ReconcilerInterface for Kubernetes API access
//   - permissionBinder: The PermissionBinder CR containing status to clean up
//   - currentNamespaces: Map of currently whitelisted namespaces (namespace -> true)
//
// Returns:
//   - error: Returns an error if status update fails, nil on success
//
// Example:
//
//	currentNamespaces := map[string]bool{"ns1": true, "ns2": true}
//	err := CleanupStatus(ctx, reconciler, binder, currentNamespaces)
//	if err != nil {
//	    logger.Error(err, "Failed to cleanup status")
//	}
func CleanupStatus(
	ctx context.Context,
	r ReconcilerInterface,
	permissionBinder *permissionv1.PermissionBinder,
	currentNamespaces map[string]bool,
) error {
	logger := log.FromContext(ctx)

	retentionDays := permissionBinder.Spec.NetworkPolicy.StatusRetentionDays
	if retentionDays == 0 {
		retentionDays = defaultStatusRetentionDays
	}

	cutoffTime := time.Now().AddDate(0, 0, -int(retentionDays))

	// Retry logic to handle race conditions (max 3 attempts)
	maxRetries := 3
	for attempt := 0; attempt < maxRetries; attempt++ {
		// Get fresh copy to avoid race conditions and preserve PR info
		key := client.ObjectKeyFromObject(permissionBinder)
		var freshBinder permissionv1.PermissionBinder
		if err := r.Get(ctx, key, &freshBinder); err != nil {
			if attempt < maxRetries-1 {
				time.Sleep(100 * time.Millisecond)
				continue
			}
			return fmt.Errorf("failed to get fresh PermissionBinder for cleanup: %w", err)
		}

		var cleanedStatus []permissionv1.NetworkPolicyStatus
		for _, statusEntry := range freshBinder.Status.NetworkPolicies {
			// If namespace is in current namespaces - keep it (preserve all fields including PR info)
			if currentNamespaces[statusEntry.Namespace] {
				cleanedStatus = append(cleanedStatus, statusEntry)
				continue
			}

			// Namespace removed - check retention
			if statusEntry.State == "removed" {
				removedTime, err := time.Parse(time.RFC3339, statusEntry.RemovedAt)
				if err == nil && removedTime.After(cutoffTime) {
					// Still in retention period - keep it (preserve all fields)
					cleanedStatus = append(cleanedStatus, statusEntry)
				}
				// Outside retention period - remove it
			} else {
				// Namespace removed but not marked - mark as removed (preserve PR info)
				statusEntry.State = "removed"
				statusEntry.RemovedAt = time.Now().Format(time.RFC3339)
				// Preserve PR info even when marking as removed
				cleanedStatus = append(cleanedStatus, statusEntry)
			}
		}

		freshBinder.Status.NetworkPolicies = cleanedStatus
		if err := r.Status().Update(ctx, &freshBinder); err != nil {
			if attempt < maxRetries-1 {
				logger.V(1).Info("Cleanup status conflict, retrying", "attempt", attempt+1)
				time.Sleep(200 * time.Millisecond)
				continue
			}
			logger.Error(err, "Failed to cleanup status after retries")
			return fmt.Errorf("failed to cleanup status: %w", err)
		}
		
		// Success - update the passed-in permissionBinder to reflect changes
		*permissionBinder = freshBinder
		return nil
	}

	return fmt.Errorf("failed to cleanup status after %d attempts", maxRetries)
}

// checkStalePRs checks for PRs that have been open for too long
func checkStalePRs(r ReconcilerInterface, 
	ctx context.Context,
	permissionBinder *permissionv1.PermissionBinder,
) error {
	logger := log.FromContext(ctx)

	thresholdStr := permissionBinder.Spec.NetworkPolicy.StalePRThreshold
	if thresholdStr == "" {
		thresholdStr = "30d"
	}

	threshold, err := time.ParseDuration(thresholdStr)
	if err != nil {
		// Default to 30 days if parsing fails
		threshold = defaultStalePRThreshold
	}

	cutoffTime := time.Now().Add(-threshold)

	for i := range permissionBinder.Status.NetworkPolicies {
		statusEntry := &permissionBinder.Status.NetworkPolicies[i]
		if statusEntry.State == "pr-created" || statusEntry.State == "pr-pending" {
			createdAt, err := time.Parse(time.RFC3339, statusEntry.CreatedAt)
			if err == nil && createdAt.Before(cutoffTime) {
				logger.Info("Security warning: PR is stale (open for too long)",
					"namespace", statusEntry.Namespace,
					"prNumber", statusEntry.PRNumber,
					"prAge", time.Since(createdAt),
					"severity", "warning",
					"security_impact", "low",
					"action", "networkpolicy_pr_stale_detected",
					"audit_trail", true)

				// Update status
				statusEntry.State = "pr-stale"
				if err := r.Status().Update(ctx, permissionBinder); err != nil {
					logger.Error(err, "Failed to update status to stale",
						"namespace", statusEntry.Namespace)
				}
			}
		}
	}

	return nil
}
