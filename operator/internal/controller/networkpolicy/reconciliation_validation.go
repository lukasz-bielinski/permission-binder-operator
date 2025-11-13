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

	"sigs.k8s.io/controller-runtime/pkg/log"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// CheckMultiplePermissionBinders validates that only one PermissionBinder CR
// has NetworkPolicy management enabled at a time.
//
// This function prevents conflicts that could arise from multiple CRs trying
// to manage NetworkPolicies simultaneously. If multiple CRs with NetworkPolicy
// enabled are found, it logs a warning and increments the
// NetworkPolicyMultipleCRsWarningTotal metric.
//
// Parameters:
//   - ctx: Context for cancellation and timeout
//   - r: ReconcilerInterface for Kubernetes API access
//
// Returns:
//   - error: Returns an error if listing PermissionBinders fails, nil otherwise
//
// Example:
//
//	err := CheckMultiplePermissionBinders(ctx, reconciler)
//	if err != nil {
//	    return fmt.Errorf("validation failed: %w", err)
//	}
func CheckMultiplePermissionBinders(
	ctx context.Context,
	r ReconcilerInterface,
) error {
	logger := log.FromContext(ctx)

	var binders permissionv1.PermissionBinderList
	if err := r.List(ctx, &binders); err != nil {
		return fmt.Errorf("failed to list PermissionBinders: %w", err)
	}

	enabledCount := 0
	for _, binder := range binders.Items {
		if binder.Spec.NetworkPolicy != nil && binder.Spec.NetworkPolicy.Enabled {
			enabledCount++
		}
	}

	if enabledCount > 1 {
		logger.Info("Warning: Multiple PermissionBinder CRs have NetworkPolicy enabled",
			"count", enabledCount,
			"severity", "warning",
			"security_impact", "medium",
			"action", "networkpolicy_multiple_crs_warning",
			"audit_trail", true,
			"recommendation", "Only one PermissionBinder CR should have NetworkPolicy enabled")

		NetworkPolicyMultipleCRsWarningTotal.Inc()
	}

	return nil
}

