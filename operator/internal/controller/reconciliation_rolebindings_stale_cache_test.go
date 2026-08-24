package controller

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// ============================================================================
// Stale-cache AlreadyExists paths (v1.8.0 status-poison fix, entry-drop
// variant): the cached Get says NotFound while the object exists server-side.
// Simulated with a shared fake store: Client's Get is intercepted to NotFound
// (the stale informer view), Create passes through and hits the store's real
// AlreadyExists, and APIReader is the uninstrumented view (server truth).
// ============================================================================

func newStaleCacheScheme() *runtime.Scheme {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)
	_ = rbacv1.AddToScheme(scheme)
	_ = permissionv1.AddToScheme(scheme)
	return scheme
}

func staleCacheBinder() *permissionv1.PermissionBinder {
	return &permissionv1.PermissionBinder{
		ObjectMeta: metav1.ObjectMeta{Name: "my-binder", Namespace: "my-namespace"},
	}
}

// TestEnsureNamespace_AlreadyExistsStaleCache: the namespace exists server-side
// but the cached Get misses it. ensureNamespace must fall through to the
// ownership/annotation path via the uncached re-read instead of failing (the
// caller would drop the whitelist entry for the whole pass).
func TestEnsureNamespace_AlreadyExistsStaleCache(t *testing.T) {
	existing := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "team-stale"}}
	base := fake.NewClientBuilder().WithScheme(newStaleCacheScheme()).WithObjects(existing).Build()
	staleClient := interceptor.NewClient(base, interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
			if _, ok := obj.(*corev1.Namespace); ok {
				return apierrors.NewNotFound(corev1.Resource("namespaces"), key.Name)
			}
			return c.Get(ctx, key, obj, opts...)
		},
	})

	r := &PermissionBinderReconciler{Client: staleClient, APIReader: base}
	if err := r.ensureNamespace(context.Background(), "team-stale", staleCacheBinder()); err != nil {
		t.Fatalf("ensureNamespace must tolerate stale-cache AlreadyExists, got: %v", err)
	}

	// The exists-path must have run: ownership annotations stamped in place.
	var ns corev1.Namespace
	if err := base.Get(context.Background(), types.NamespacedName{Name: "team-stale"}, &ns); err != nil {
		t.Fatalf("namespace disappeared: %v", err)
	}
	if ns.Annotations[AnnotationPermissionBinder] != "my-binder" ||
		ns.Annotations[AnnotationPermissionBinderNamespace] != "my-namespace" {
		t.Errorf("ownership annotations not stamped after stale-cache fall-through: %v", ns.Annotations)
	}
}

// TestCreateRoleBinding_AlreadyExistsStaleCache: same race on the LDAP-group
// RoleBinding. Must return managed=true with the ownership/update path applied.
func TestCreateRoleBinding_AlreadyExistsStaleCache(t *testing.T) {
	existing := &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{Name: "team-stale-admin", Namespace: "team-stale"},
		RoleRef: rbacv1.RoleRef{
			APIGroup: "rbac.authorization.k8s.io", Kind: "ClusterRole", Name: "admin",
		},
	}
	base := fake.NewClientBuilder().WithScheme(newStaleCacheScheme()).WithObjects(existing).Build()
	staleClient := interceptor.NewClient(base, interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
			if _, ok := obj.(*rbacv1.RoleBinding); ok {
				return apierrors.NewNotFound(rbacv1.Resource("rolebindings"), key.Name)
			}
			return c.Get(ctx, key, obj, opts...)
		},
	})

	r := &PermissionBinderReconciler{Client: staleClient, APIReader: base}
	managed, err := r.createRoleBinding(context.Background(), "team-stale", "team-stale-admin",
		"admin", "COMPANY-K8S-team-stale-admin", "admin", staleCacheBinder())
	if err != nil {
		t.Fatalf("createRoleBinding must tolerate stale-cache AlreadyExists, got: %v", err)
	}
	if !managed {
		t.Fatal("createRoleBinding must report managed=true after stale-cache fall-through")
	}

	var rb rbacv1.RoleBinding
	if err := base.Get(context.Background(), types.NamespacedName{Name: "team-stale-admin", Namespace: "team-stale"}, &rb); err != nil {
		t.Fatalf("RoleBinding disappeared: %v", err)
	}
	if rb.Annotations[AnnotationPermissionBinder] != "my-binder" {
		t.Errorf("ownership annotations not stamped after stale-cache fall-through: %v", rb.Annotations)
	}
	if len(rb.Subjects) != 1 || rb.Subjects[0].Name != "COMPANY-K8S-team-stale-admin" {
		t.Errorf("subjects not enforced on the exists-path: %v", rb.Subjects)
	}
}

// TestCreateRoleBinding_ForeignClaimStillRefusedAfterStaleCache: the ownership
// gate must survive the new fall-through - a foreign-claimed RoleBinding found
// via the uncached re-read is still refused (managed=false, no mutation).
func TestCreateRoleBinding_ForeignClaimStillRefusedAfterStaleCache(t *testing.T) {
	existing := &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{
			Name: "team-stale-admin", Namespace: "team-stale",
			Annotations: map[string]string{
				AnnotationPermissionBinder:          "other-binder",
				AnnotationPermissionBinderNamespace: "other-namespace",
			},
		},
		RoleRef: rbacv1.RoleRef{
			APIGroup: "rbac.authorization.k8s.io", Kind: "ClusterRole", Name: "view",
		},
	}
	base := fake.NewClientBuilder().WithScheme(newStaleCacheScheme()).WithObjects(existing).Build()
	staleClient := interceptor.NewClient(base, interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
			if _, ok := obj.(*rbacv1.RoleBinding); ok {
				return apierrors.NewNotFound(rbacv1.Resource("rolebindings"), key.Name)
			}
			return c.Get(ctx, key, obj, opts...)
		},
	})

	r := &PermissionBinderReconciler{Client: staleClient, APIReader: base}
	managed, err := r.createRoleBinding(context.Background(), "team-stale", "team-stale-admin",
		"admin", "COMPANY-K8S-team-stale-admin", "admin", staleCacheBinder())
	if err != nil {
		t.Fatalf("foreign claim must be a clean refusal, got error: %v", err)
	}
	if managed {
		t.Fatal("foreign-claimed RoleBinding must NOT be reported managed after stale-cache fall-through")
	}

	var rb rbacv1.RoleBinding
	if err := base.Get(context.Background(), types.NamespacedName{Name: "team-stale-admin", Namespace: "team-stale"}, &rb); err != nil {
		t.Fatalf("RoleBinding disappeared: %v", err)
	}
	if rb.RoleRef.Name != "view" {
		t.Errorf("foreign RoleBinding was mutated: %v", rb.RoleRef)
	}
}
