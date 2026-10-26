package controller

// Tests for the inventory label (LabelManagedBy) on the ServiceAccount flow.
//
// Before this change only the group flow (namespaces + group RoleBindings)
// stamped permission-binder.io/managed-by, so a cluster-wide
// `-l permission-binder.io/managed-by` listing silently omitted every
// ServiceAccount and SA RoleBinding the operator had created, and SAFE-MODE
// cleanup could not orphan-annotate them on CR deletion.
//
// Stamping that label also pulls SA RoleBindings into getManagedRoleBindings,
// which feeds the group-flow deletion loops in reconcileAllManagedResources -
// hence the guard asserted by TestReconcileAllManagedResources_* below.

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// TestProcessServiceAccounts_InventoryLabelStampedOnCreate verifies that newly
// created ServiceAccounts and their RoleBindings carry the inventory label.
func TestProcessServiceAccounts_InventoryLabelStampedOnCreate(t *testing.T) {
	const ns = "team-a"
	k8sClient := newSAFakeClient()

	if _, err := ProcessServiceAccounts(context.Background(), k8sClient, ns,
		map[string]string{"deploy": "edit"}, "", "my-binder", "my-namespace"); err != nil {
		t.Fatalf("ProcessServiceAccounts returned error: %v", err)
	}

	fullSAName := GenerateServiceAccountName("", ns, "deploy")
	var sa corev1.ServiceAccount
	if err := k8sClient.Get(context.Background(), types.NamespacedName{Name: fullSAName, Namespace: ns}, &sa); err != nil {
		t.Fatalf("ServiceAccount not created: %v", err)
	}
	if got := sa.Labels[LabelManagedBy]; got != ManagedByValue {
		t.Errorf("ServiceAccount is missing the inventory label: got %q, want %q", got, ManagedByValue)
	}
	// The recommended Kubernetes labels must survive alongside it.
	if got := sa.Labels[labelAppManagedBy]; got != ManagedByValue {
		t.Errorf("ServiceAccount lost app.kubernetes.io/managed-by: %q", got)
	}

	var rb rbacv1.RoleBinding
	if err := k8sClient.Get(context.Background(), types.NamespacedName{Name: "sa-" + ns + "-deploy", Namespace: ns}, &rb); err != nil {
		t.Fatalf("RoleBinding not created: %v", err)
	}
	if got := rb.Labels[LabelManagedBy]; got != ManagedByValue {
		t.Errorf("SA RoleBinding is missing the inventory label: got %q, want %q", got, ManagedByValue)
	}
	if got := rb.Labels[labelAppManagedBy]; got != ManagedByValue {
		t.Errorf("SA RoleBinding lost app.kubernetes.io/managed-by: %q", got)
	}
}

// TestProcessServiceAccounts_InventoryLabelBackfilledOnExistingSA verifies the
// upgrade path: a ServiceAccount created by an older operator version (no
// inventory label) is relabelled in place, without touching its spec.
func TestProcessServiceAccounts_InventoryLabelBackfilledOnExistingSA(t *testing.T) {
	const ns = "team-a"
	fullSAName := GenerateServiceAccountName("", ns, "deploy")
	existing := &corev1.ServiceAccount{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fullSAName,
			Namespace: ns,
			Annotations: map[string]string{
				AnnotationPermissionBinder:          "my-binder",
				AnnotationPermissionBinderNamespace: "my-namespace",
			},
			Labels: map[string]string{labelAppManagedBy: ManagedByValue},
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
	if got := sa.Labels[LabelManagedBy]; got != ManagedByValue {
		t.Errorf("Inventory label not backfilled on existing ServiceAccount: got %q", got)
	}
	if got := sa.Labels[labelAppManagedBy]; got != ManagedByValue {
		t.Errorf("Backfill clobbered the pre-existing labels: %v", sa.Labels)
	}
}

// TestProcessServiceAccounts_InventoryLabelNotBackfilledOnForeignSA verifies
// that the backfill respects the issue #43 ownership gate: a ServiceAccount
// claimed by another PermissionBinder must not be written to at all.
func TestProcessServiceAccounts_InventoryLabelNotBackfilledOnForeignSA(t *testing.T) {
	const ns = "team-a"
	fullSAName := GenerateServiceAccountName("", ns, "deploy")
	existing := &corev1.ServiceAccount{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fullSAName,
			Namespace: ns,
			Annotations: map[string]string{
				AnnotationPermissionBinder:          "other-binder",
				AnnotationPermissionBinderNamespace: "other-namespace",
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
	if _, ok := sa.Labels[LabelManagedBy]; ok {
		t.Errorf("Foreign-claimed ServiceAccount was relabelled: %v", sa.Labels)
	}
}

// TestProcessServiceAccounts_InventoryLabelBackfilledOnLegacyRoleBinding
// verifies that a legacy SA RoleBinding whose spec already matches the mapping
// (no delete+recreate needed) still gets the inventory label via the in-place
// ownership re-stamp - the permissions must not be dropped to relabel it.
func TestProcessServiceAccounts_InventoryLabelBackfilledOnLegacyRoleBinding(t *testing.T) {
	const ns = "team-a"
	existing := saRoleBindingFixture(ns, "deploy", "edit", map[string]string{
		AnnotationPermissionBinder:          "my-binder",
		AnnotationPermissionBinderNamespace: "my-namespace",
	})
	k8sClient := newSAFakeClient(existing)

	if _, err := ProcessServiceAccounts(context.Background(), k8sClient, ns,
		map[string]string{"deploy": "edit"}, "", "my-binder", "my-namespace"); err != nil {
		t.Fatalf("ProcessServiceAccounts returned error: %v", err)
	}

	var rb rbacv1.RoleBinding
	if err := k8sClient.Get(context.Background(), types.NamespacedName{Name: "sa-" + ns + "-deploy", Namespace: ns}, &rb); err != nil {
		t.Fatalf("RoleBinding disappeared: %v", err)
	}
	if got := rb.Labels[LabelManagedBy]; got != ManagedByValue {
		t.Errorf("Inventory label not backfilled on legacy SA RoleBinding: got %q", got)
	}
	if rb.RoleRef.Name != "edit" {
		t.Errorf("Relabel changed the RoleRef: %s", rb.RoleRef.Name)
	}
}

// TestReconcileAllManagedResources_SARoleBindingPreserved is the regression
// guard for the side effect of stamping the inventory label: SA RoleBindings
// now show up in getManagedRoleBindings, and both deletion loops in
// reconcileAllManagedResources would otherwise remove them - the prefix loop
// unconditionally (a ServiceAccount subject matches no LDAP prefix), the
// obsolete-role loop as soon as a role name is extractable from the name.
//
// The group RoleBinding in the same pass asserts the loops still work.
func TestReconcileAllManagedResources_SARoleBindingPreserved(t *testing.T) {
	const ns = "team-a"
	const ownerName = "my-binder"
	const ownerNamespace = "my-namespace"

	saRB := saRoleBindingFixture(ns, "deploy", "edit", map[string]string{
		AnnotationCreatedBy:                 ManagedByValue,
		AnnotationServiceAccount:            GenerateServiceAccountName("", ns, "deploy"),
		AnnotationSAType:                    "deploy",
		AnnotationPermissionBinder:          ownerName,
		AnnotationPermissionBinderNamespace: ownerNamespace,
	})
	saRB.Labels = map[string]string{LabelManagedBy: ManagedByValue}

	// Group RoleBinding whose group carries a prefix that is no longer in the
	// spec - the prefix loop must still delete this one.
	groupRB := &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ns + "-admin",
			Namespace: ns,
			Labels:    map[string]string{LabelManagedBy: ManagedByValue},
			Annotations: map[string]string{
				AnnotationManagedBy:                 ManagedByValue,
				AnnotationRole:                      "admin",
				AnnotationPermissionBinder:          ownerName,
				AnnotationPermissionBinderNamespace: ownerNamespace,
			},
		},
		RoleRef: rbacv1.RoleRef{APIGroup: rbacAPIGroup, Kind: clusterRoleKind, Name: "admin"},
		Subjects: []rbacv1.Subject{
			{Kind: "Group", Name: "OLD-PFX-" + ns + "-admin"},
		},
	}

	k8sClient := newSAFakeClient(saRB, groupRB)
	reconciler := &PermissionBinderReconciler{Client: k8sClient, Scheme: k8sClient.Scheme()}

	permissionBinder := &permissionv1.PermissionBinder{
		ObjectMeta: metav1.ObjectMeta{Name: ownerName, Namespace: ownerNamespace},
		Spec: permissionv1.PermissionBinderSpec{
			Prefixes:    []string{"NEW-PFX"},
			RoleMapping: map[string]string{"admin": "admin"},
		},
	}

	if err := reconciler.reconcileAllManagedResources(context.Background(), permissionBinder); err != nil {
		t.Fatalf("reconcileAllManagedResources returned error: %v", err)
	}

	var survivingSARB rbacv1.RoleBinding
	if err := k8sClient.Get(context.Background(),
		types.NamespacedName{Name: "sa-" + ns + "-deploy", Namespace: ns}, &survivingSARB); err != nil {
		t.Fatalf("SA RoleBinding was deleted by the group-flow cleanup: %v", err)
	}

	var deletedGroupRB rbacv1.RoleBinding
	if err := k8sClient.Get(context.Background(),
		types.NamespacedName{Name: ns + "-admin", Namespace: ns}, &deletedGroupRB); err == nil {
		t.Errorf("Group RoleBinding with a stale prefix was not deleted - the guard is too broad")
	}
}

// TestIsServiceAccountRoleBinding covers the marker precedence: annotations
// first, ServiceAccount subject as the fallback for RoleBindings written
// before those annotations existed.
func TestIsServiceAccountRoleBinding(t *testing.T) {
	tests := []struct {
		name        string
		roleBinding *rbacv1.RoleBinding
		want        bool
	}{
		{
			name: "SA annotation marker",
			roleBinding: &rbacv1.RoleBinding{
				ObjectMeta: metav1.ObjectMeta{
					Annotations: map[string]string{AnnotationServiceAccount: "team-a-sa-deploy"},
				},
			},
			want: true,
		},
		{
			name: "sa-type annotation marker",
			roleBinding: &rbacv1.RoleBinding{
				ObjectMeta: metav1.ObjectMeta{
					Annotations: map[string]string{AnnotationSAType: "deploy"},
				},
			},
			want: true,
		},
		{
			name: "no annotations, ServiceAccount subject fallback",
			roleBinding: &rbacv1.RoleBinding{
				Subjects: []rbacv1.Subject{{Kind: serviceAccountKind, Name: "team-a-sa-deploy"}},
			},
			want: true,
		},
		{
			name: "group RoleBinding",
			roleBinding: &rbacv1.RoleBinding{
				ObjectMeta: metav1.ObjectMeta{
					Annotations: map[string]string{AnnotationRole: "admin"},
				},
				Subjects: []rbacv1.Subject{{Kind: "Group", Name: "PFX-team-a-admin"}},
			},
			want: false,
		},
		{
			name:        "no annotations, no subjects",
			roleBinding: &rbacv1.RoleBinding{},
			want:        false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isServiceAccountRoleBinding(tt.roleBinding); got != tt.want {
				t.Errorf("isServiceAccountRoleBinding() = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestStampBackfillBookkeeping verifies the per-process forced-pass ledger
// that makes the backfill actually run after an operator upgrade: the skip
// guard sees no change on a steady-state cluster, so the first pass per CR per
// process must be forced, and only a completed pass clears the debt.
func TestStampBackfillBookkeeping(t *testing.T) {
	reconciler := &PermissionBinderReconciler{}
	const uid types.UID = "11111111-2222-3333-4444-555555555555"

	if !reconciler.needsStampBackfill(uid) {
		t.Error("A CR never seen by this process must be due a forced pass")
	}
	// Still due: an incomplete pass does not clear the debt.
	if !reconciler.needsStampBackfill(uid) {
		t.Error("needsStampBackfill must not clear the debt by itself")
	}

	reconciler.markStampBackfilled(uid)
	if reconciler.needsStampBackfill(uid) {
		t.Error("A completed pass must clear the debt")
	}

	// Independent CRs keep independent ledgers.
	const otherUID types.UID = "99999999-8888-7777-6666-555555555555"
	if !reconciler.needsStampBackfill(otherUID) {
		t.Error("Marking one CR must not clear another CR's debt")
	}
}
