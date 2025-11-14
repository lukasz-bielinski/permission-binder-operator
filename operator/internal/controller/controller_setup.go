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
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// SetupWithManager sets up the controller with the Manager.
func (r *PermissionBinderReconciler) SetupWithManager(mgr ctrl.Manager) error {
	// Create an indexer for PermissionBinders by ConfigMap reference
	// This allows efficient lookup of PermissionBinders that reference a specific ConfigMap
	indexerFunc := func(obj client.Object) []string {
		pb, ok := obj.(*permissionv1.PermissionBinder)
		if !ok {
			return []string{}
		}
		// Index by "namespace/name" format for ConfigMap reference
		return []string{fmt.Sprintf("%s/%s", pb.Spec.ConfigMapNamespace, pb.Spec.ConfigMapName)}
	}

	// Register the indexer with the cache
	if err := mgr.GetCache().IndexField(
		context.Background(),
		&permissionv1.PermissionBinder{},
		"configMapRef",
		indexerFunc,
	); err != nil {
		return fmt.Errorf("failed to set up indexer for PermissionBinder: %w", err)
	}

	return ctrl.NewControllerManagedBy(mgr).
		For(&permissionv1.PermissionBinder{}, builder.WithPredicates(permissionBinderPredicate())).
		Watches(
			&corev1.ConfigMap{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				configMap, ok := obj.(*corev1.ConfigMap)
				if !ok {
					return []reconcile.Request{}
				}
				return r.mapConfigMapToPermissionBinder(ctx, configMap)
			}),
			builder.WithPredicates(r.configMapPredicate(mgr)),
		).
		Complete(r)
}

// isConfigMapReferenced checks if a ConfigMap is referenced by any PermissionBinder
// Uses indexer for efficient lookup instead of listing all PermissionBinders
func (r *PermissionBinderReconciler) isConfigMapReferenced(c client.Client, obj client.Object) bool {
	configMap, ok := obj.(*corev1.ConfigMap)
	if !ok {
		return false
	}

	ctx := context.Background()
	var permissionBinders permissionv1.PermissionBinderList

	// Use indexer to find PermissionBinders that reference this ConfigMap
	indexKey := fmt.Sprintf("%s/%s", configMap.Namespace, configMap.Name)
	if err := c.List(ctx, &permissionBinders, client.MatchingFields{"configMapRef": indexKey}); err != nil {
		// If indexer lookup fails, fallback to allowing the event through (safer)
		// This ensures we don't miss events if there's a temporary cache/indexer issue
		return true
	}

	// If any PermissionBinders reference this ConfigMap, return true
	return len(permissionBinders.Items) > 0
}

// mapConfigMapToPermissionBinder maps ConfigMap changes to PermissionBinder reconciliation
// This ensures operator reacts to ConfigMap changes automatically
// Note: This function is only called for ConfigMaps that pass the predicate filter
// (i.e., ConfigMaps referenced by at least one PermissionBinder)
func (r *PermissionBinderReconciler) mapConfigMapToPermissionBinder(ctx context.Context, obj *corev1.ConfigMap) []reconcile.Request {
	logger := log.FromContext(ctx)

	// Get all PermissionBinders that might be using this ConfigMap
	var permissionBinders permissionv1.PermissionBinderList
	if err := r.List(ctx, &permissionBinders); err != nil {
		if r.DebugMode {
			logger.Error(err, "🔍 DEBUG: Failed to list PermissionBinders for ConfigMap watch")
		}
		return []reconcile.Request{}
	}

	var requests []reconcile.Request
	for _, pb := range permissionBinders.Items {
		// Check if this ConfigMap is referenced by this PermissionBinder
		if pb.Spec.ConfigMapName == obj.Name && pb.Spec.ConfigMapNamespace == obj.Namespace {
			if r.DebugMode {
				logger.Info("🔍 DEBUG: ConfigMap watch triggered reconciliation",
					"configMapName", obj.Name,
					"configMapNamespace", obj.Namespace,
					"configMapResourceVersion", obj.ResourceVersion,
					"permissionBinder", types.NamespacedName{Name: pb.Name, Namespace: pb.Namespace},
					"timestamp", time.Now().Format(time.RFC3339Nano))
			}
			requests = append(requests, reconcile.Request{
				NamespacedName: types.NamespacedName{
					Name:      pb.Name,
					Namespace: pb.Namespace,
				},
			})
		}
	}

	return requests
}

