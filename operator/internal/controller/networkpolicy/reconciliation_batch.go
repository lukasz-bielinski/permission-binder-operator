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

	"sigs.k8s.io/controller-runtime/pkg/log"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// ProcessNetworkPoliciesForNamespaces processes NetworkPolicy management for multiple namespaces in batches.
//
// This function processes namespaces in configurable batches to avoid overwhelming
// the Git repository and Kubernetes API. It supports:
//   - Configurable batch size (default: 5 namespaces)
//   - Sleep intervals between namespaces (default: 3s)
//   - Sleep intervals between batches (default: 60s)
//
// Batch processing configuration is read from permissionBinder.Spec.NetworkPolicy.BatchProcessing.
// If not configured, default values are used.
//
// Parameters:
//   - ctx: Context for cancellation and timeout
//   - r: ReconcilerInterface for Kubernetes API access
//   - permissionBinder: The PermissionBinder CR containing configuration
//   - namespaces: List of namespace names to process
//
// Returns:
//   - error: Returns an error if batch processing fails, nil on success
//
// Example:
//
//	namespaces := []string{"ns1", "ns2", "ns3", "ns4", "ns5"}
//	err := ProcessNetworkPoliciesForNamespaces(ctx, reconciler, binder, namespaces)
//	if err != nil {
//	    logger.Error(err, "Failed to process namespaces")
//	}
func ProcessNetworkPoliciesForNamespaces(
	ctx context.Context,
	r ReconcilerInterface,
	permissionBinder *permissionv1.PermissionBinder,
	namespaces []string,
) error {
	logger := log.FromContext(ctx)

	// Get batch processing config
	batchConfig := permissionBinder.Spec.NetworkPolicy.BatchProcessing
	batchSize := defaultBatchSize
	sleepBetweenNamespaces := defaultSleepBetweenNamespaces
	sleepBetweenBatches := defaultSleepBetweenBatches

	if batchConfig != nil {
		if batchConfig.BatchSize > 0 {
			batchSize = batchConfig.BatchSize
		}
		if batchConfig.SleepBetweenNamespaces != "" {
			if duration, err := time.ParseDuration(batchConfig.SleepBetweenNamespaces); err == nil {
				sleepBetweenNamespaces = duration
			}
		}
		if batchConfig.SleepBetweenBatches != "" {
			if duration, err := time.ParseDuration(batchConfig.SleepBetweenBatches); err == nil {
				sleepBetweenBatches = duration
			}
		}
	}

	// Filter namespaces - skip those that already have status (optimization)
	var namespaceList []string
	for _, ns := range namespaces {
		if !hasNetworkPolicyStatus(permissionBinder, ns) {
			namespaceList = append(namespaceList, ns)
		} else {
			logger.V(1).Info("Skipping namespace - already processed",
				"namespace", ns,
				"reason", "has_status_entry")
		}
	}

	// Batch processing
	batches := chunkNamespaces(namespaceList, batchSize)

	for i, batch := range batches {
		logger.Info("Processing NetworkPolicy batch (event-driven)",
			"batch", i+1,
			"totalBatches", len(batches),
			"batchSize", len(batch))

		for _, namespace := range batch {
			if err := ProcessNetworkPolicyForNamespace(ctx, r, permissionBinder, namespace); err != nil {
				logger.Error(err, "Failed to process NetworkPolicy", "namespace", namespace)
				// Continue with other namespaces
			}

			// Sleep between namespaces (rate limiting for Git API)
			if namespace != batch[len(batch)-1] {
				time.Sleep(sleepBetweenNamespaces)
			}
		}

		// Sleep between batches (GitOps sync delay - allows GitOps to apply changes)
		if i < len(batches)-1 {
			logger.Info("Waiting before processing next batch (GitOps sync delay)",
				"nextBatch", i+2,
				"sleep", sleepBetweenBatches.String())
			time.Sleep(sleepBetweenBatches)
		}
	}

	return nil
}

