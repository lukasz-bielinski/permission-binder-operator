package metadata

import (
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

var testNow = time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)

func groupStamp() Stamp {
	return Stamp{
		ManagedBy:      "permission-binder-operator",
		Owner:          "my-binder",
		OwnerNamespace: "my-namespace",
		Role:           "read-only",
	}
}

func saStamp() Stamp {
	return Stamp{
		ManagedBy:       "permission-binder-operator",
		Owner:           "my-binder",
		OwnerNamespace:  "my-namespace",
		SAType:          "deploy",
		ServiceAccount:  "team-a-sa-deploy",
		AppComponent:    "service-account-binding",
		AppName:         "my-binder",
		LegacyCreatedBy: true,
	}
}

// TestAnnotations_OmitsEmptyExtras verifies that the per-kind extras are only
// rendered when they apply - a namespace must not grow an empty role
// annotation just because RoleBindings have one.
func TestAnnotations_OmitsEmptyExtras(t *testing.T) {
	annotations := Stamp{ManagedBy: "pbo", Owner: "b", OwnerNamespace: "ns"}.Annotations(testNow)

	for _, key := range []string{AnnotationManagedBy, AnnotationCreatedAt, AnnotationPermissionBinder, AnnotationPermissionBinderNamespace} {
		if annotations[key] == "" {
			t.Errorf("Base annotation %s missing", key)
		}
	}
	for _, key := range []string{AnnotationRole, AnnotationSAType, AnnotationServiceAccount, AnnotationCreatedBy} {
		if _, ok := annotations[key]; ok {
			t.Errorf("Optional annotation %s rendered although unset", key)
		}
	}
	if got := annotations[AnnotationCreatedAt]; got != "2026-10-26T12:00:00Z" {
		t.Errorf("created-at is not RFC3339 UTC: %q", got)
	}
}

// TestAnnotations_ServiceAccountFlow verifies the SA flow's extras, including
// the deprecated created-by that live ServiceAccounts still carry.
func TestAnnotations_ServiceAccountFlow(t *testing.T) {
	annotations := saStamp().Annotations(testNow)

	if annotations[AnnotationCreatedBy] != "permission-binder-operator" {
		t.Errorf("Deprecated created-by not written: %v", annotations)
	}
	if annotations[AnnotationManagedBy] != annotations[AnnotationCreatedBy] {
		t.Errorf("created-by and managed-by disagree: %v", annotations)
	}
	if annotations[AnnotationSAType] != "deploy" || annotations[AnnotationServiceAccount] != "team-a-sa-deploy" {
		t.Errorf("SA extras wrong: %v", annotations)
	}
}

// TestLabels verifies that the inventory label is unconditional and the
// recommended Kubernetes labels need both component and name.
func TestLabels(t *testing.T) {
	bare := Stamp{ManagedBy: "pbo"}.Labels()
	if bare[LabelManagedBy] != "pbo" {
		t.Errorf("Inventory label missing: %v", bare)
	}
	if _, ok := bare[LabelAppComponent]; ok {
		t.Errorf("Recommended labels rendered without component/name: %v", bare)
	}

	full := saStamp().Labels()
	for _, key := range []string{LabelManagedBy, LabelAppManagedBy, LabelAppComponent, LabelAppName} {
		if full[key] == "" {
			t.Errorf("Label %s missing: %v", key, full)
		}
	}
}

// TestApply_ReportsChangeAndIsIdempotent is the property the callers depend on
// to skip a no-op Update (and the ResourceVersion churn it causes).
func TestApply_ReportsChangeAndIsIdempotent(t *testing.T) {
	object := &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: "sa", Namespace: "ns"}}

	if !Apply(object, groupStamp(), testNow) {
		t.Fatal("First Apply on a bare object must report a change")
	}
	if Apply(object, groupStamp(), testNow) {
		t.Error("Second identical Apply must report no change")
	}
	// A different clock must not count as a change: created-at is write-once.
	if Apply(object, groupStamp(), testNow.Add(time.Hour)) {
		t.Error("Apply must not rewrite created-at on a later pass")
	}
	if got := object.Annotations[AnnotationCreatedAt]; got != "2026-10-26T12:00:00Z" {
		t.Errorf("created-at was rewritten: %q", got)
	}
}

// TestApply_PreservesForeignKeysAndFixesDrift verifies that Apply reconciles
// only the keys it owns: a user's own annotations and labels survive, while a
// tampered owner stamp is corrected.
func TestApply_PreservesForeignKeysAndFixesDrift(t *testing.T) {
	object := &corev1.ServiceAccount{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "sa",
			Namespace: "ns",
			Annotations: map[string]string{
				"team.example.com/owner":   "payments",
				AnnotationPermissionBinder: "someone-else",
				AnnotationCreatedAt:        "2020-01-01T00:00:00Z",
			},
			Labels: map[string]string{"team.example.com/tier": "gold"},
		},
	}

	if !Apply(object, groupStamp(), testNow) {
		t.Fatal("Apply must report the corrected owner stamp as a change")
	}
	if object.Annotations["team.example.com/owner"] != "payments" {
		t.Error("Apply dropped a foreign annotation")
	}
	if object.Labels["team.example.com/tier"] != "gold" {
		t.Error("Apply dropped a foreign label")
	}
	if object.Annotations[AnnotationPermissionBinder] != "my-binder" {
		t.Errorf("Apply did not correct the owner annotation: %v", object.Annotations)
	}
	if object.Annotations[AnnotationCreatedAt] != "2020-01-01T00:00:00Z" {
		t.Errorf("Apply overwrote an existing created-at: %v", object.Annotations)
	}
}

// TestOrphanLifecycle covers the SAFE-MODE round trip: mark on CR deletion,
// detect, clear on adoption - each step reporting whether it changed anything.
func TestOrphanLifecycle(t *testing.T) {
	object := &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: "sa", Namespace: "ns"}}

	if IsOrphaned(object) {
		t.Error("A fresh object must not look orphaned")
	}
	if ClearOrphan(object) {
		t.Error("ClearOrphan on a non-orphan must report no change")
	}

	if !MarkOrphaned(object, OrphanedByPermissionBinderDeletion, testNow) {
		t.Fatal("MarkOrphaned must report a change")
	}
	if !IsOrphaned(object) {
		t.Error("IsOrphaned must see the marker it just set")
	}
	if object.Annotations[AnnotationOrphanedBy] != OrphanedByPermissionBinderDeletion {
		t.Errorf("orphaned-by wrong: %v", object.Annotations)
	}
	if MarkOrphaned(object, OrphanedByPermissionBinderDeletion, testNow.Add(time.Hour)) {
		t.Error("Re-marking an already-orphaned object must report no change (no Update, no churn)")
	}

	if !ClearOrphan(object) {
		t.Fatal("ClearOrphan on an orphan must report a change")
	}
	if _, ok := object.Annotations[AnnotationOrphanedAt]; ok {
		t.Errorf("orphaned-at survived adoption: %v", object.Annotations)
	}
	if _, ok := object.Annotations[AnnotationOrphanedBy]; ok {
		t.Errorf("orphaned-by survived adoption: %v", object.Annotations)
	}
}

// TestApply_DoesNotTouchOrphanMarkers: adoption is an explicit step with its
// own metric and log line, so Apply must leave the markers to ClearOrphan.
func TestApply_DoesNotTouchOrphanMarkers(t *testing.T) {
	object := &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: "sa", Namespace: "ns"}}
	MarkOrphaned(object, OrphanedByPermissionBinderDeletion, testNow)

	Apply(object, groupStamp(), testNow)

	if !IsOrphaned(object) {
		t.Error("Apply silently cleared the orphan marker")
	}
}
