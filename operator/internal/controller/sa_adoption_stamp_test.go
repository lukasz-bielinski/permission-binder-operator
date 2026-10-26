package controller

// Adoption must stamp. "Adoption" is every path where the operator wanted to
// create a resource and found it already there - the ordinary exists-branch
// and the stale-cache AlreadyExists race alike - and an adopted resource has
// to end up carrying the same annotations and labels as a freshly created one.
//
// The ServiceAccount flow used to fail both halves of that: the exists-branch
// never re-stamped ownership, and the AlreadyExists path skipped the metadata
// step entirely.

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	"github.com/permission-binder-operator/operator/internal/metadata"
)

// assertFullSAStamp checks the whole contract for a managed ServiceAccount,
// not just the key under test - the point of the stamp is that it is complete.
func assertFullSAStamp(t *testing.T, sa *corev1.ServiceAccount, owner, ownerNS, saType, role string) {
	t.Helper()

	want := map[string]string{
		metadata.AnnotationManagedBy:                 ManagedByValue,
		metadata.AnnotationCreatedBy:                 ManagedByValue,
		metadata.AnnotationPermissionBinder:          owner,
		metadata.AnnotationPermissionBinderNamespace: ownerNS,
		metadata.AnnotationSAType:                    saType,
		metadata.AnnotationRole:                      role,
	}
	for key, value := range want {
		if sa.Annotations[key] != value {
			t.Errorf("ServiceAccount annotation %s = %q, want %q", key, sa.Annotations[key], value)
		}
	}
	if sa.Annotations[metadata.AnnotationCreatedAt] == "" {
		t.Error("ServiceAccount is missing created-at")
	}
	for _, key := range []string{metadata.LabelManagedBy, metadata.LabelAppManagedBy, metadata.LabelAppComponent, metadata.LabelAppName} {
		if sa.Labels[key] == "" {
			t.Errorf("ServiceAccount label %s missing: %v", key, sa.Labels)
		}
	}
}

// TestProcessServiceAccounts_AdoptionStampsExistingServiceAccount covers the
// ordinary adopt path: a ServiceAccount that exists with no stamp at all (hand
// made, or created by a version before the contract) is fully stamped.
func TestProcessServiceAccounts_AdoptionStampsExistingServiceAccount(t *testing.T) {
	const ns = "team-a"
	fullSAName := GenerateServiceAccountName("", ns, "deploy")
	existing := &corev1.ServiceAccount{
		ObjectMeta: metav1.ObjectMeta{Name: fullSAName, Namespace: ns},
	}
	k8sClient := newSAFakeClient(existing)

	if _, err := ProcessServiceAccounts(context.Background(), k8sClient, ns,
		map[string]string{"deploy": "edit"}, "", "my-binder", "my-namespace"); err != nil {
		t.Fatalf("ProcessServiceAccounts returned error: %v", err)
	}

	var sa corev1.ServiceAccount
	if err := k8sClient.Get(context.Background(), types.NamespacedName{Name: fullSAName, Namespace: ns}, &sa); err != nil {
		t.Fatalf("ServiceAccount disappeared: %v", err)
	}
	assertFullSAStamp(t, &sa, "my-binder", "my-namespace", "deploy", "edit")
}

// TestProcessServiceAccounts_StaleCacheAdoptionStampsServiceAccount covers the
// race: the cached Get says NotFound, the Create loses to the live object, and
// the re-read has to stamp what it found. Pre-fix this path logged "already
// exists, continuing" and left the ServiceAccount unstamped.
func TestProcessServiceAccounts_StaleCacheAdoptionStampsServiceAccount(t *testing.T) {
	const ns = "team-race-adopt"
	fullSAName := GenerateServiceAccountName("", ns, "deploy")
	existing := &corev1.ServiceAccount{
		ObjectMeta: metav1.ObjectMeta{Name: fullSAName, Namespace: ns},
	}

	// First Get on the ServiceAccount is stale (NotFound); the re-read after
	// AlreadyExists sees the live object.
	staleGets := 0
	k8sClient := newSAFakeClientWithInterceptors(interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
			if _, ok := obj.(*corev1.ServiceAccount); ok && staleGets == 0 {
				staleGets++
				return apierrors.NewNotFound(corev1.Resource("serviceaccounts"), key.Name)
			}
			return c.Get(ctx, key, obj, opts...)
		},
	}, existing)

	if _, err := ProcessServiceAccounts(context.Background(), k8sClient, ns,
		map[string]string{"deploy": "edit"}, "", "my-binder", "my-namespace"); err != nil {
		t.Fatalf("ProcessServiceAccounts returned error: %v", err)
	}
	if staleGets != 1 {
		t.Fatalf("the stale-cache path was not exercised (staleGets=%d)", staleGets)
	}

	var sa corev1.ServiceAccount
	if err := k8sClient.Get(context.Background(), types.NamespacedName{Name: fullSAName, Namespace: ns}, &sa); err != nil {
		t.Fatalf("ServiceAccount disappeared: %v", err)
	}
	assertFullSAStamp(t, &sa, "my-binder", "my-namespace", "deploy", "edit")
}

// TestProcessServiceAccounts_AdoptionStampsExistingRoleBinding covers the same
// for the SA RoleBinding: an unstamped RoleBinding whose spec already matches
// is re-stamped in place - no delete+recreate, so the granted permissions are
// never dropped.
func TestProcessServiceAccounts_AdoptionStampsExistingRoleBinding(t *testing.T) {
	const ns = "team-a"
	existing := saRoleBindingFixture(ns, "deploy", "edit", nil)
	k8sClient := newSAFakeClient(existing)

	if _, err := ProcessServiceAccounts(context.Background(), k8sClient, ns,
		map[string]string{"deploy": "edit"}, "", "my-binder", "my-namespace"); err != nil {
		t.Fatalf("ProcessServiceAccounts returned error: %v", err)
	}

	var rb rbacv1.RoleBinding
	if err := k8sClient.Get(context.Background(), types.NamespacedName{Name: "sa-" + ns + "-deploy", Namespace: ns}, &rb); err != nil {
		t.Fatalf("RoleBinding disappeared: %v", err)
	}

	fullSAName := GenerateServiceAccountName("", ns, "deploy")
	want := map[string]string{
		metadata.AnnotationManagedBy:                 ManagedByValue,
		metadata.AnnotationCreatedBy:                 ManagedByValue,
		metadata.AnnotationPermissionBinder:          "my-binder",
		metadata.AnnotationPermissionBinderNamespace: "my-namespace",
		metadata.AnnotationSAType:                    "deploy",
		metadata.AnnotationServiceAccount:            fullSAName,
	}
	for key, value := range want {
		if rb.Annotations[key] != value {
			t.Errorf("RoleBinding annotation %s = %q, want %q", key, rb.Annotations[key], value)
		}
	}
	if rb.Annotations[metadata.AnnotationCreatedAt] == "" {
		t.Error("RoleBinding is missing created-at")
	}
	if rb.Labels[metadata.LabelManagedBy] != ManagedByValue {
		t.Errorf("RoleBinding is missing the inventory label: %v", rb.Labels)
	}
	if rb.RoleRef.Name != "edit" {
		t.Errorf("Re-stamp changed the RoleRef: %s", rb.RoleRef.Name)
	}
}

// TestProcessServiceAccounts_AdoptionClearsOrphanMarkers verifies that picking
// up a ServiceAccount that SAFE-MODE cleanup had orphaned is a real adoption:
// the markers go, the stamp lands.
func TestProcessServiceAccounts_AdoptionClearsOrphanMarkers(t *testing.T) {
	const ns = "team-a"
	fullSAName := GenerateServiceAccountName("", ns, "deploy")
	existing := &corev1.ServiceAccount{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fullSAName,
			Namespace: ns,
			Annotations: map[string]string{
				metadata.AnnotationPermissionBinder:          "old-binder",
				metadata.AnnotationPermissionBinderNamespace: "old-namespace",
				metadata.AnnotationOrphanedAt:                "2026-01-01T00:00:00Z",
				metadata.AnnotationOrphanedBy:                metadata.OrphanedByPermissionBinderDeletion,
			},
		},
	}
	k8sClient := newSAFakeClient(existing)

	if _, err := ProcessServiceAccounts(context.Background(), k8sClient, ns,
		map[string]string{"deploy": "edit"}, "", "my-binder", "my-namespace"); err != nil {
		t.Fatalf("ProcessServiceAccounts returned error: %v", err)
	}

	var sa corev1.ServiceAccount
	if err := k8sClient.Get(context.Background(), types.NamespacedName{Name: fullSAName, Namespace: ns}, &sa); err != nil {
		t.Fatalf("ServiceAccount disappeared: %v", err)
	}
	if _, ok := sa.Annotations[metadata.AnnotationOrphanedAt]; ok {
		t.Errorf("Orphan marker survived adoption: %v", sa.Annotations)
	}
	if sa.Annotations[metadata.AnnotationPermissionBinder] != "my-binder" {
		t.Errorf("Adopted ServiceAccount still claims the old owner: %v", sa.Annotations)
	}
	assertFullSAStamp(t, &sa, "my-binder", "my-namespace", "deploy", "edit")
}
