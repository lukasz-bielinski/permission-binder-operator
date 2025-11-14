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
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/predicate"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// configMapPredicate filters ConfigMap events to only those referenced by PermissionBinders
// Uses the indexer for efficient lookup instead of listing all PermissionBinders
func (r *PermissionBinderReconciler) configMapPredicate(mgr interface {
	GetClient() client.Client
}) predicate.Predicate {
	return predicate.Funcs{
		CreateFunc: func(e event.CreateEvent) bool {
			return r.isConfigMapReferenced(mgr.GetClient(), e.Object)
		},
		UpdateFunc: func(e event.UpdateEvent) bool {
			// Only process if ResourceVersion changed (avoid unnecessary reconciliations)
			// This filters out status-only updates on ConfigMaps
			oldCM := e.ObjectOld.(*corev1.ConfigMap)
			newCM := e.ObjectNew.(*corev1.ConfigMap)

			// Only process if data or metadata changed, not just status
			if oldCM.ResourceVersion == newCM.ResourceVersion {
				return false
			}

			// Check if actual data changed (not just status)
			// ConfigMaps don't have status subresource, so ResourceVersion change means data changed
			return r.isConfigMapReferenced(mgr.GetClient(), e.ObjectNew)
		},
		DeleteFunc: func(e event.DeleteEvent) bool {
			return r.isConfigMapReferenced(mgr.GetClient(), e.Object)
		},
		GenericFunc: func(e event.GenericEvent) bool {
			return r.isConfigMapReferenced(mgr.GetClient(), e.Object)
		},
	}
}

// permissionBinderPredicate filters PermissionBinder events to ignore status-only updates
// This prevents reconciliation loops caused by status updates
func permissionBinderPredicate() predicate.Predicate {
	return predicate.Funcs{
		CreateFunc: func(e event.CreateEvent) bool {
			return true
		},
		UpdateFunc: func(e event.UpdateEvent) bool {
			// Only reconcile if spec or metadata changed, not status-only changes
			oldObj := e.ObjectOld.(*permissionv1.PermissionBinder)
			newObj := e.ObjectNew.(*permissionv1.PermissionBinder)

			// Check if spec changed
			if oldObj.Generation != newObj.Generation {
				return true
			}

			// Check if deletion timestamp changed (object is being deleted)
			if oldObj.DeletionTimestamp.IsZero() != newObj.DeletionTimestamp.IsZero() {
				return true
			}

			// Check if finalizers changed
			if len(oldObj.Finalizers) != len(newObj.Finalizers) {
				return true
			}

			// Ignore status-only updates
			return false
		},
		DeleteFunc: func(e event.DeleteEvent) bool {
			return true
		},
		GenericFunc: func(e event.GenericEvent) bool {
			return true
		},
	}
}

