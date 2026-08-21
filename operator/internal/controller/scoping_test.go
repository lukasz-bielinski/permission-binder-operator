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
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/event"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// TestReconcilesNamespace covers the RECONCILE_NAMESPACES allowlist check
// (issue #43): empty = all namespaces, otherwise exact namespace membership.
func TestReconcilesNamespace(t *testing.T) {
	tests := []struct {
		name       string
		allowlist  []string
		namespace  string
		reconciles bool
	}{
		{
			name:       "empty allowlist reconciles every namespace",
			allowlist:  nil,
			namespace:  "any-namespace",
			reconciles: true,
		},
		{
			name:       "namespace in allowlist",
			allowlist:  []string{"instance-a", "instance-b"},
			namespace:  "instance-b",
			reconciles: true,
		},
		{
			name:       "namespace not in allowlist",
			allowlist:  []string{"instance-a"},
			namespace:  "instance-b",
			reconciles: false,
		},
		{
			name:       "no prefix or substring matching",
			allowlist:  []string{"instance-a"},
			namespace:  "instance-a-extra",
			reconciles: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := &PermissionBinderReconciler{ReconcileNamespaces: tt.allowlist}
			if got := r.reconcilesNamespace(tt.namespace); got != tt.reconciles {
				t.Errorf("reconcilesNamespace(%q) with allowlist %v = %v, want %v",
					tt.namespace, tt.allowlist, got, tt.reconciles)
			}
		})
	}
}

// TestPermissionBinderPredicateNamespaceScoping verifies that the
// PermissionBinder event predicate drops all event types for CRs outside
// RECONCILE_NAMESPACES while keeping the existing status-only-update
// suppression for CRs it does reconcile.
func TestPermissionBinderPredicateNamespaceScoping(t *testing.T) {
	newPB := func(namespace string, generation int64) *permissionv1.PermissionBinder {
		return &permissionv1.PermissionBinder{
			ObjectMeta: metav1.ObjectMeta{
				Name:       "example",
				Namespace:  namespace,
				Generation: generation,
			},
		}
	}

	scoped := (&PermissionBinderReconciler{ReconcileNamespaces: []string{"instance-a"}}).permissionBinderPredicate()
	unscoped := (&PermissionBinderReconciler{}).permissionBinderPredicate()

	// Create/Delete/Generic: allowed namespace passes, foreign namespace is dropped
	if !scoped.Create(event.CreateEvent{Object: newPB("instance-a", 1)}) {
		t.Error("Create event for an allowed namespace should pass")
	}
	if scoped.Create(event.CreateEvent{Object: newPB("instance-b", 1)}) {
		t.Error("Create event for a foreign namespace should be dropped")
	}
	if !scoped.Delete(event.DeleteEvent{Object: newPB("instance-a", 1)}) {
		t.Error("Delete event for an allowed namespace should pass")
	}
	if scoped.Delete(event.DeleteEvent{Object: newPB("instance-b", 1)}) {
		t.Error("Delete event for a foreign namespace should be dropped")
	}
	if !scoped.Generic(event.GenericEvent{Object: newPB("instance-a", 1)}) {
		t.Error("Generic event for an allowed namespace should pass")
	}
	if scoped.Generic(event.GenericEvent{Object: newPB("instance-b", 1)}) {
		t.Error("Generic event for a foreign namespace should be dropped")
	}

	// Update: spec change in an allowed namespace passes, in a foreign one is dropped
	specChange := event.UpdateEvent{ObjectOld: newPB("instance-a", 1), ObjectNew: newPB("instance-a", 2)}
	if !scoped.Update(specChange) {
		t.Error("spec-change Update in an allowed namespace should pass")
	}
	foreignSpecChange := event.UpdateEvent{ObjectOld: newPB("instance-b", 1), ObjectNew: newPB("instance-b", 2)}
	if scoped.Update(foreignSpecChange) {
		t.Error("spec-change Update in a foreign namespace should be dropped")
	}

	// Status-only updates stay suppressed for reconciled CRs (pre-existing behavior)
	statusOnly := event.UpdateEvent{ObjectOld: newPB("instance-a", 1), ObjectNew: newPB("instance-a", 1)}
	if scoped.Update(statusOnly) {
		t.Error("status-only Update should stay suppressed even for an allowed namespace")
	}

	// Empty allowlist keeps current behavior: everything passes the namespace gate
	if !unscoped.Create(event.CreateEvent{Object: newPB("instance-b", 1)}) {
		t.Error("Create event should pass with an empty allowlist")
	}
}
