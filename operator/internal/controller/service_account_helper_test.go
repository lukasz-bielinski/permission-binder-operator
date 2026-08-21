package controller

import (
	"context"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// TestGenerateServiceAccountName tests the GenerateServiceAccountName function
func TestGenerateServiceAccountName(t *testing.T) {
	tests := []struct {
		name      string
		pattern   string
		namespace string
		saName    string
		expected  string
	}{
		// Default pattern tests
		{
			name:      "Default pattern (empty)",
			pattern:   "",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "my-app-sa-deploy",
		},
		{
			name:      "Default pattern explicit",
			pattern:   "{namespace}-sa-{name}",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "my-app-sa-deploy",
		},
		{
			name:      "Default pattern with runtime SA",
			pattern:   "{namespace}-sa-{name}",
			namespace: "my-app",
			saName:    "runtime",
			expected:  "my-app-sa-runtime",
		},
		{
			name:      "Default pattern with backup SA",
			pattern:   "{namespace}-sa-{name}",
			namespace: "my-app",
			saName:    "backup",
			expected:  "my-app-sa-backup",
		},

		// Alternative pattern tests
		{
			name:      "Pattern: sa-{namespace}-{name}",
			pattern:   "sa-{namespace}-{name}",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "sa-my-app-deploy",
		},
		{
			name:      "Pattern: {namespace}-{name}",
			pattern:   "{namespace}-{name}",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "my-app-deploy",
		},
		{
			name:      "Pattern: {name}-{namespace}",
			pattern:   "{name}-{namespace}",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "deploy-my-app",
		},
		{
			name:      "Pattern: {namespace}-svc-{name}",
			pattern:   "{namespace}-svc-{name}",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "my-app-svc-deploy",
		},

		// Custom patterns
		{
			name:      "Custom: k8s-{namespace}-{name}-sa",
			pattern:   "k8s-{namespace}-{name}-sa",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "k8s-my-app-deploy-sa",
		},
		{
			name:      "Custom: {name}.{namespace}.svc",
			pattern:   "{name}.{namespace}.svc",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "deploy.my-app.svc",
		},

		// Namespace with hyphens
		{
			name:      "Namespace with multiple hyphens",
			pattern:   "{namespace}-sa-{name}",
			namespace: "my-app-staging-v2",
			saName:    "deploy",
			expected:  "my-app-staging-v2-sa-deploy",
		},
		{
			name:      "Namespace with numbers",
			pattern:   "{namespace}-sa-{name}",
			namespace: "app-123",
			saName:    "deploy",
			expected:  "app-123-sa-deploy",
		},
		{
			name:      "Namespace starts with number",
			pattern:   "{namespace}-sa-{name}",
			namespace: "123-app",
			saName:    "deploy",
			expected:  "123-app-sa-deploy",
		},

		// SA name variations
		{
			name:      "SA name with hyphens",
			pattern:   "{namespace}-sa-{name}",
			namespace: "my-app",
			saName:    "ci-cd",
			expected:  "my-app-sa-ci-cd",
		},
		{
			name:      "SA name with numbers",
			pattern:   "{namespace}-sa-{name}",
			namespace: "my-app",
			saName:    "worker-01",
			expected:  "my-app-sa-worker-01",
		},

		// Single character inputs
		{
			name:      "Single character namespace",
			pattern:   "{namespace}-sa-{name}",
			namespace: "a",
			saName:    "deploy",
			expected:  "a-sa-deploy",
		},
		{
			name:      "Single character SA name",
			pattern:   "{namespace}-sa-{name}",
			namespace: "my-app",
			saName:    "d",
			expected:  "my-app-sa-d",
		},

		// Very long names
		{
			name:      "Very long namespace",
			pattern:   "{namespace}-sa-{name}",
			namespace: "this-is-a-very-long-namespace-name-with-many-segments",
			saName:    "deploy",
			expected:  "this-is-a-very-long-namespace-name-with-many-segments-sa-deploy",
		},
		{
			name:      "Very long SA name",
			pattern:   "{namespace}-sa-{name}",
			namespace: "my-app",
			saName:    "very-long-service-account-name",
			expected:  "my-app-sa-very-long-service-account-name",
		},

		// Pattern with only one variable
		{
			name:      "Pattern with only namespace",
			pattern:   "sa-{namespace}",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "sa-my-app",
		},
		{
			name:      "Pattern with only name",
			pattern:   "sa-{name}",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "sa-deploy",
		},

		// Pattern with no variables
		{
			name:      "Pattern with no variables (static)",
			pattern:   "static-sa-name",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "static-sa-name",
		},

		// Multiple occurrences of variables
		{
			name:      "Pattern with multiple {namespace}",
			pattern:   "{namespace}-{namespace}-sa-{name}",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "my-app-my-app-sa-deploy",
		},
		{
			name:      "Pattern with multiple {name}",
			pattern:   "{namespace}-sa-{name}-{name}",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "my-app-sa-deploy-deploy",
		},

		// Empty inputs
		{
			name:      "Empty namespace",
			pattern:   "{namespace}-sa-{name}",
			namespace: "",
			saName:    "deploy",
			expected:  "-sa-deploy",
		},
		{
			name:      "Empty SA name",
			pattern:   "{namespace}-sa-{name}",
			namespace: "my-app",
			saName:    "",
			expected:  "my-app-sa-",
		},
		{
			name:      "Both empty",
			pattern:   "{namespace}-sa-{name}",
			namespace: "",
			saName:    "",
			expected:  "-sa-",
		},

		// Real-world examples from documentation
		{
			name:      "Example: Deploy SA",
			pattern:   "{namespace}-sa-{name}",
			namespace: "backend-api",
			saName:    "deploy",
			expected:  "backend-api-sa-deploy",
		},
		{
			name:      "Example: Runtime SA",
			pattern:   "{namespace}-sa-{name}",
			namespace: "backend-api",
			saName:    "runtime",
			expected:  "backend-api-sa-runtime",
		},
		{
			name:      "Example: Backup SA",
			pattern:   "{namespace}-sa-{name}",
			namespace: "database",
			saName:    "backup",
			expected:  "database-sa-backup",
		},

		// CI/CD integration examples
		{
			name:      "CI/CD: Bamboo deploy",
			pattern:   "{namespace}-sa-{name}",
			namespace: "app-production",
			saName:    "bamboo-deploy",
			expected:  "app-production-sa-bamboo-deploy",
		},
		{
			name:      "CI/CD: Jenkins deploy",
			pattern:   "{namespace}-sa-{name}",
			namespace: "app-staging",
			saName:    "jenkins",
			expected:  "app-staging-sa-jenkins",
		},

		// Edge case: Pattern with special characters
		{
			name:      "Pattern with dots",
			pattern:   "{namespace}.{name}.sa",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "my-app.deploy.sa",
		},
		{
			name:      "Pattern with underscores",
			pattern:   "{namespace}_{name}_sa",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "my-app_deploy_sa",
		},

		// Edge case: Namespace/name with special chars (Kubernetes allows hyphens and numbers)
		{
			name:      "Namespace with dots (Kubernetes allows)",
			pattern:   "{namespace}-sa-{name}",
			namespace: "my.app.v1",
			saName:    "deploy",
			expected:  "my.app.v1-sa-deploy",
		},

		// Pattern case sensitivity
		{
			name:      "Pattern with uppercase (should not match)",
			pattern:   "{NAMESPACE}-sa-{NAME}",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "{NAMESPACE}-sa-{NAME}", // Variables won't be replaced
		},
		{
			name:      "Pattern with mixed case",
			pattern:   "{Namespace}-sa-{Name}",
			namespace: "my-app",
			saName:    "deploy",
			expected:  "{Namespace}-sa-{Name}", // Variables won't be replaced
		},

		// Multi-tenant scenarios
		{
			name:      "Multi-tenant: tenant1",
			pattern:   "{namespace}-sa-{name}",
			namespace: "tenant1-app1",
			saName:    "deploy",
			expected:  "tenant1-app1-sa-deploy",
		},
		{
			name:      "Multi-tenant: tenant2",
			pattern:   "{namespace}-sa-{name}",
			namespace: "tenant2-project-456",
			saName:    "runtime",
			expected:  "tenant2-project-456-sa-runtime",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := GenerateServiceAccountName(tt.pattern, tt.namespace, tt.saName)

			if result != tt.expected {
				t.Errorf("Expected %q, got %q", tt.expected, result)
			}
		})
	}
}

// TestGenerateServiceAccountName_Idempotency tests that function is idempotent
func TestGenerateServiceAccountName_Idempotency(t *testing.T) {
	pattern := "{namespace}-sa-{name}"
	namespace := "my-app"
	saName := "deploy"

	// Call function multiple times with same inputs
	result1 := GenerateServiceAccountName(pattern, namespace, saName)
	result2 := GenerateServiceAccountName(pattern, namespace, saName)
	result3 := GenerateServiceAccountName(pattern, namespace, saName)

	// All results should be identical
	if result1 != result2 || result2 != result3 {
		t.Errorf("Function is not idempotent: %q, %q, %q", result1, result2, result3)
	}

	expected := "my-app-sa-deploy"
	if result1 != expected {
		t.Errorf("Expected %q, got %q", expected, result1)
	}
}

// TestGenerateServiceAccountName_KubernetesNamingConventions tests compliance
func TestGenerateServiceAccountName_KubernetesNamingConventions(t *testing.T) {
	// Kubernetes ServiceAccount names must:
	// - Be at most 253 characters (DNS subdomain name)
	// - Contain only lowercase alphanumeric characters, '-' or '.'
	// - Start and end with an alphanumeric character

	tests := []struct {
		name        string
		pattern     string
		namespace   string
		saName      string
		description string
	}{
		{
			name:        "Valid: lowercase with hyphens",
			pattern:     "{namespace}-sa-{name}",
			namespace:   "my-app",
			saName:      "deploy",
			description: "Should generate valid Kubernetes name",
		},
		{
			name:        "Valid: with numbers",
			pattern:     "{namespace}-sa-{name}",
			namespace:   "app-123",
			saName:      "worker-01",
			description: "Should generate valid Kubernetes name",
		},
		{
			name:        "Valid: with dots",
			pattern:     "{namespace}.{name}.sa",
			namespace:   "my-app",
			saName:      "deploy",
			description: "Should generate valid Kubernetes name",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := GenerateServiceAccountName(tt.pattern, tt.namespace, tt.saName)

			// Basic validation (real validation would use Kubernetes API validation)
			if len(result) > 253 {
				t.Errorf("%s: Result too long (%d characters): %q", tt.description, len(result), result)
			}

			if len(result) == 0 {
				t.Errorf("%s: Result is empty", tt.description)
			}
		})
	}
}

// BenchmarkGenerateServiceAccountName - Performance benchmarks
func BenchmarkGenerateServiceAccountName(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		GenerateServiceAccountName("{namespace}-sa-{name}", "my-app", "deploy")
	}
}

func BenchmarkGenerateServiceAccountName_DefaultPattern(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		GenerateServiceAccountName("", "my-app", "deploy")
	}
}

func BenchmarkGenerateServiceAccountName_ComplexPattern(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		GenerateServiceAccountName("k8s-{namespace}-{name}-sa-v1", "my-app-staging-v2", "deploy-worker")
	}
}

func BenchmarkGenerateServiceAccountName_LongNames(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		GenerateServiceAccountName(
			"{namespace}-sa-{name}",
			"this-is-a-very-long-namespace-name-with-many-segments",
			"very-long-service-account-name",
		)
	}
}

// ============================================================================
// ProcessServiceAccounts tests (fake K8s client) - issue #43 ownership gate
// ============================================================================

func newSAFakeClient(objs ...client.Object) client.Client {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)
	_ = rbacv1.AddToScheme(scheme)

	return fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(objs...).
		Build()
}

func saRoleBindingFixture(namespace, saName, roleName string, annotations map[string]string) *rbacv1.RoleBinding {
	fullSAName := GenerateServiceAccountName("", namespace, saName)
	return &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{
			Name:        "sa-" + namespace + "-" + saName,
			Namespace:   namespace,
			Annotations: annotations,
		},
		RoleRef: rbacv1.RoleRef{
			APIGroup: "rbac.authorization.k8s.io",
			Kind:     "ClusterRole",
			Name:     roleName,
		},
		Subjects: []rbacv1.Subject{
			{Kind: "ServiceAccount", Name: fullSAName, Namespace: namespace},
		},
	}
}

// TestProcessServiceAccounts_ForeignOwnedRoleBindingNotStolen verifies the
// issue #43 gate: an SA RoleBinding claimed by ANOTHER PermissionBinder must
// not be delete+recreated even when its RoleRef differs from the mapping.
func TestProcessServiceAccounts_ForeignOwnedRoleBindingNotStolen(t *testing.T) {
	const ns = "team-a"
	existing := saRoleBindingFixture(ns, "deploy", "view", map[string]string{
		AnnotationPermissionBinder:          "other-binder",
		AnnotationPermissionBinderNamespace: "other-namespace",
	})
	k8sClient := newSAFakeClient(existing)

	conflictsBefore := testutil.ToFloat64(ownershipConflictsTotal.WithLabelValues("serviceaccount_rolebinding"))

	processed, err := ProcessServiceAccounts(context.Background(), k8sClient, ns,
		map[string]string{"deploy": "edit"}, "", "my-binder", "my-namespace")
	if err != nil {
		t.Fatalf("ProcessServiceAccounts returned error: %v", err)
	}

	var rb rbacv1.RoleBinding
	if err := k8sClient.Get(context.Background(), types.NamespacedName{Name: "sa-" + ns + "-deploy", Namespace: ns}, &rb); err != nil {
		t.Fatalf("RoleBinding disappeared - it was stolen/deleted: %v", err)
	}
	if rb.RoleRef.Name != "view" {
		t.Errorf("RoleBinding RoleRef was overwritten: expected view, got %s", rb.RoleRef.Name)
	}
	if rb.Annotations[AnnotationPermissionBinder] != "other-binder" ||
		rb.Annotations[AnnotationPermissionBinderNamespace] != "other-namespace" {
		t.Errorf("Foreign ownership annotations were rewritten: %v", rb.Annotations)
	}
	if len(processed) != 0 {
		t.Errorf("Refused RoleBinding must not be reported as processed, got %v", processed)
	}

	conflictsAfter := testutil.ToFloat64(ownershipConflictsTotal.WithLabelValues("serviceaccount_rolebinding"))
	if conflictsAfter != conflictsBefore+1 {
		t.Errorf("Expected ownership conflict counter to increase by 1, got %v -> %v", conflictsBefore, conflictsAfter)
	}
}

// TestProcessServiceAccounts_OwnedRoleBindingRoleChangeRecreated verifies the
// pre-existing behavior survives the gate: a RoleBinding owned by the calling
// PermissionBinder IS delete+recreated when the mapped role changes.
func TestProcessServiceAccounts_OwnedRoleBindingRoleChangeRecreated(t *testing.T) {
	const ns = "team-a"
	existing := saRoleBindingFixture(ns, "deploy", "view", map[string]string{
		AnnotationPermissionBinder:          "my-binder",
		AnnotationPermissionBinderNamespace: "my-namespace",
	})
	k8sClient := newSAFakeClient(existing)

	processed, err := ProcessServiceAccounts(context.Background(), k8sClient, ns,
		map[string]string{"deploy": "edit"}, "", "my-binder", "my-namespace")
	if err != nil {
		t.Fatalf("ProcessServiceAccounts returned error: %v", err)
	}

	var rb rbacv1.RoleBinding
	if err := k8sClient.Get(context.Background(), types.NamespacedName{Name: "sa-" + ns + "-deploy", Namespace: ns}, &rb); err != nil {
		t.Fatalf("RoleBinding not found after update: %v", err)
	}
	if rb.RoleRef.Name != "edit" {
		t.Errorf("Owned RoleBinding was not updated: expected edit, got %s", rb.RoleRef.Name)
	}
	if rb.Annotations[AnnotationPermissionBinder] != "my-binder" ||
		rb.Annotations[AnnotationPermissionBinderNamespace] != "my-namespace" {
		t.Errorf("Ownership annotations missing after recreate: %v", rb.Annotations)
	}
	if len(processed) != 1 {
		t.Errorf("Expected 1 processed SA, got %v", processed)
	}
}

// TestProcessServiceAccounts_LegacyNameOnlyRoleBindingTakeable verifies
// backward compatibility: a legacy RoleBinding annotated with the owner name
// only (no namespace annotation) is still updated, and the recreate stamps the
// namespace annotation retroactively.
func TestProcessServiceAccounts_LegacyNameOnlyRoleBindingTakeable(t *testing.T) {
	const ns = "team-a"
	existing := saRoleBindingFixture(ns, "deploy", "view", map[string]string{
		AnnotationPermissionBinder: "my-binder", // legacy: no namespace annotation
	})
	k8sClient := newSAFakeClient(existing)

	if _, err := ProcessServiceAccounts(context.Background(), k8sClient, ns,
		map[string]string{"deploy": "edit"}, "", "my-binder", "my-namespace"); err != nil {
		t.Fatalf("ProcessServiceAccounts returned error: %v", err)
	}

	var rb rbacv1.RoleBinding
	if err := k8sClient.Get(context.Background(), types.NamespacedName{Name: "sa-" + ns + "-deploy", Namespace: ns}, &rb); err != nil {
		t.Fatalf("RoleBinding not found after update: %v", err)
	}
	if rb.RoleRef.Name != "edit" {
		t.Errorf("Legacy-owned RoleBinding was not updated: expected edit, got %s", rb.RoleRef.Name)
	}
	if rb.Annotations[AnnotationPermissionBinderNamespace] != "my-namespace" {
		t.Errorf("Namespace annotation not stamped retroactively on legacy RoleBinding: %v", rb.Annotations)
	}
}

// TestProcessServiceAccounts_ManagedByValueOverrideStamping verifies that an
// overridden MANAGED_BY_VALUE is actually stamped on created ServiceAccounts
// and RoleBindings (issue #43: the SA flow used to hardcode the default).
func TestProcessServiceAccounts_ManagedByValueOverrideStamping(t *testing.T) {
	original := ManagedByValue
	t.Cleanup(func() { ManagedByValue = original })
	ManagedByValue = "permission-binder-operator-e2e-7"

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
	if got := sa.Labels["app.kubernetes.io/managed-by"]; got != "permission-binder-operator-e2e-7" {
		t.Errorf("SA managed-by label ignores MANAGED_BY_VALUE override: %q", got)
	}
	if got := sa.Annotations[AnnotationCreatedBy]; got != "permission-binder-operator-e2e-7" {
		t.Errorf("SA created-by annotation ignores MANAGED_BY_VALUE override: %q", got)
	}
	if sa.Annotations[AnnotationPermissionBinder] != "my-binder" ||
		sa.Annotations[AnnotationPermissionBinderNamespace] != "my-namespace" {
		t.Errorf("SA ownership annotations wrong: %v", sa.Annotations)
	}

	var rb rbacv1.RoleBinding
	if err := k8sClient.Get(context.Background(), types.NamespacedName{Name: "sa-" + ns + "-deploy", Namespace: ns}, &rb); err != nil {
		t.Fatalf("RoleBinding not created: %v", err)
	}
	if got := rb.Labels["app.kubernetes.io/managed-by"]; got != "permission-binder-operator-e2e-7" {
		t.Errorf("RB managed-by label ignores MANAGED_BY_VALUE override: %q", got)
	}
	if got := rb.Annotations[AnnotationCreatedBy]; got != "permission-binder-operator-e2e-7" {
		t.Errorf("RB created-by annotation ignores MANAGED_BY_VALUE override: %q", got)
	}
}
