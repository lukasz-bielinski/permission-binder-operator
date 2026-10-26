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

// Package metadata owns the annotation and label contract the operator stamps
// on every resource it creates, adopts or orphans.
//
// Before this package the contract lived in seven hand-rolled if-chains across
// two flows, and they had drifted apart: the group flow (namespaces, group
// RoleBindings) stamped permission-binder.io/managed-by plus created-at, while
// the ServiceAccount flow stamped a differently named created-by, no
// created-at, and never re-stamped ownership on an object it adopted. A single
// Stamp value now describes the desired metadata and Apply writes it
// idempotently, so "which keys does a managed object carry" has exactly one
// answer in exactly one place.
//
// Scope: the permission-binder.io/* keys on RBAC resources. The NetworkPolicy
// GitOps flow writes network-policy.permission-binder.io/* keys on manifests it
// renders into a Git repository, not on live cluster objects it owns; that
// contract is deliberately separate and is not handled here.
package metadata

import (
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const (
	// AnnotationManagedBy names the operator instance that manages the
	// resource. Mirrors LabelManagedBy, which is the selectable form.
	AnnotationManagedBy = "permission-binder.io/managed-by"

	// AnnotationCreatedAt is when the operator first stamped the resource,
	// RFC3339. It is never rewritten, so on a resource adopted later it marks
	// the adoption, not the resource's own creation.
	AnnotationCreatedAt = "permission-binder.io/created-at"

	// AnnotationPermissionBinder identifies the name of the owning
	// PermissionBinder CR.
	AnnotationPermissionBinder = "permission-binder.io/permission-binder"

	// AnnotationPermissionBinderNamespace identifies the namespace of the
	// owning PermissionBinder CR. It makes ownership unique per operator
	// instance when multiple instances run in parallel (e.g. isolated e2e
	// tests), so that a CR name collision between instances no longer causes
	// cross-instance deletion.
	AnnotationPermissionBinderNamespace = "permission-binder.io/permission-binder-namespace"

	// AnnotationRole carries the full role key from spec.roleMapping (group
	// flow) or spec.serviceAccountMapping (ServiceAccount), so a role name
	// containing hyphens survives round-tripping through the resource name.
	AnnotationRole = "permission-binder.io/role"

	// AnnotationSAType is the ServiceAccount mapping key (deploy, runtime, …).
	AnnotationSAType = "permission-binder.io/sa-type"

	// AnnotationServiceAccount is the ServiceAccount a RoleBinding binds.
	AnnotationServiceAccount = "permission-binder.io/service-account"

	// AnnotationCreatedBy is the ServiceAccount flow's historical spelling of
	// AnnotationManagedBy.
	//
	// Deprecated: kept because it is what every ServiceAccount and SA
	// RoleBinding in the field carries today; both keys are written with the
	// same value. Read AnnotationManagedBy.
	AnnotationCreatedBy = "permission-binder.io/created-by"

	// AnnotationOrphanedAt and AnnotationOrphanedBy are the orphan markers set
	// by SAFE-MODE cleanup when a PermissionBinder is deleted; their presence
	// makes a resource adoptable by another CR.
	AnnotationOrphanedAt = "permission-binder.io/orphaned-at"
	AnnotationOrphanedBy = "permission-binder.io/orphaned-by"

	// OrphanedByPermissionBinderDeletion is the AnnotationOrphanedBy value
	// stamped by SAFE-MODE cleanup.
	OrphanedByPermissionBinderDeletion = "permission-binder-deletion"

	// LabelManagedBy is the selectable form of AnnotationManagedBy and the
	// only way the operator finds its own resources cluster-wide (SAFE-MODE
	// cleanup, the managed/orphaned gauges, every runbook one-liner). Every
	// managed resource carries it.
	LabelManagedBy = "permission-binder.io/managed-by"

	// The recommended Kubernetes labels, stamped where a component/name pair
	// is meaningful (the ServiceAccount flow).
	LabelAppManagedBy = "app.kubernetes.io/managed-by"
	LabelAppComponent = "app.kubernetes.io/component"
	LabelAppName      = "app.kubernetes.io/name"
)

// Stamp is the desired ownership metadata for one resource. The zero value
// stamps nothing; ManagedBy, Owner and OwnerNamespace are what every managed
// resource carries, the rest are per-kind extras left empty when they do not
// apply.
type Stamp struct {
	// ManagedBy is the operator instance value (controller.ManagedByValue).
	// Passed in rather than read from a global so this package holds no
	// mutable state and multi-instance tests stay honest.
	ManagedBy string

	// Owner and OwnerNamespace identify the PermissionBinder CR.
	Owner          string
	OwnerNamespace string

	// Role, SAType and ServiceAccount are the per-kind extras.
	Role           string
	SAType         string
	ServiceAccount string

	// AppComponent and AppName add the recommended Kubernetes labels. Both
	// must be set for either to be stamped.
	AppComponent string
	AppName      string

	// LegacyCreatedBy also writes the deprecated AnnotationCreatedBy. Set for
	// the ServiceAccount flow, whose live objects carry it.
	LegacyCreatedBy bool
}

// Annotations renders the annotations for a resource being created. now fills
// AnnotationCreatedAt.
func (s Stamp) Annotations(now time.Time) map[string]string {
	annotations := map[string]string{
		AnnotationManagedBy:                 s.ManagedBy,
		AnnotationCreatedAt:                 now.UTC().Format(time.RFC3339),
		AnnotationPermissionBinder:          s.Owner,
		AnnotationPermissionBinderNamespace: s.OwnerNamespace,
	}
	if s.LegacyCreatedBy {
		annotations[AnnotationCreatedBy] = s.ManagedBy
	}
	if s.Role != "" {
		annotations[AnnotationRole] = s.Role
	}
	if s.SAType != "" {
		annotations[AnnotationSAType] = s.SAType
	}
	if s.ServiceAccount != "" {
		annotations[AnnotationServiceAccount] = s.ServiceAccount
	}
	return annotations
}

// Labels renders the labels for a resource being created.
func (s Stamp) Labels() map[string]string {
	labels := map[string]string{LabelManagedBy: s.ManagedBy}
	if s.AppComponent != "" && s.AppName != "" {
		labels[LabelAppManagedBy] = s.ManagedBy
		labels[LabelAppComponent] = s.AppComponent
		labels[LabelAppName] = s.AppName
	}
	return labels
}

// Apply writes the stamp onto an existing object and reports whether anything
// changed, so callers can skip a no-op Update (and the ResourceVersion churn
// and watch traffic that comes with it).
//
// Idempotent and additive: keys the stamp does not describe are left alone, so
// a user's own annotations survive, and AnnotationCreatedAt is filled only
// when absent - an adopted resource keeps the timestamp it already had.
// Orphan markers are NOT touched here; adoption is an explicit step with its
// own metric and log line (see ClearOrphan).
//
// Callers must gate this on the ownership check: Apply does not know whether
// the object is claimed by another PermissionBinder.
func Apply(object metav1.Object, stamp Stamp, now time.Time) bool {
	changed := false

	annotations := object.GetAnnotations()
	if annotations == nil {
		annotations = make(map[string]string)
		changed = true
	}
	for key, value := range stamp.Annotations(now) {
		// created-at records the first stamp, so it is written only when
		// absent - every other key is reconciled to the desired value.
		if key == AnnotationCreatedAt {
			if annotations[key] == "" {
				annotations[key] = value
				changed = true
			}
			continue
		}
		if annotations[key] != value {
			annotations[key] = value
			changed = true
		}
	}
	object.SetAnnotations(annotations)

	labels := object.GetLabels()
	if labels == nil {
		labels = make(map[string]string)
		changed = true
	}
	for key, value := range stamp.Labels() {
		if labels[key] != value {
			labels[key] = value
			changed = true
		}
	}
	object.SetLabels(labels)

	return changed
}

// IsOrphaned reports whether SAFE-MODE cleanup has marked the object as
// orphaned.
func IsOrphaned(object metav1.Object) bool {
	return object.GetAnnotations()[AnnotationOrphanedAt] != ""
}

// ClearOrphan removes the orphan markers and reports whether it had to,
// letting the caller log the adoption and count it once.
func ClearOrphan(object metav1.Object) bool {
	annotations := object.GetAnnotations()
	if annotations[AnnotationOrphanedAt] == "" && annotations[AnnotationOrphanedBy] == "" {
		return false
	}
	delete(annotations, AnnotationOrphanedAt)
	delete(annotations, AnnotationOrphanedBy)
	object.SetAnnotations(annotations)
	return true
}

// MarkOrphaned stamps the orphan markers used by SAFE-MODE cleanup, which
// preserves resources instead of deleting them when a PermissionBinder goes
// away. Reports whether anything changed.
func MarkOrphaned(object metav1.Object, orphanedBy string, now time.Time) bool {
	annotations := object.GetAnnotations()
	if annotations == nil {
		annotations = make(map[string]string)
	}
	if annotations[AnnotationOrphanedAt] != "" && annotations[AnnotationOrphanedBy] == orphanedBy {
		return false
	}
	annotations[AnnotationOrphanedAt] = now.UTC().Format(time.RFC3339)
	annotations[AnnotationOrphanedBy] = orphanedBy
	object.SetAnnotations(annotations)
	return true
}
