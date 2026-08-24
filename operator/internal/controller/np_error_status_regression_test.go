package controller

// Manager-driven regression test for issue #54: NetworkPolicy git failures
// never reached CR status (e2e test 53).
//
// Mirrors example/tests/test-implementations/test-53-networkpolicy---git-
// operations-failures.sh against a real manager: a PermissionBinder with
// NetworkPolicy enabled points at an unreachable git remote (the e2e uses
// invalid credentials; here the clone dials 127.0.0.1:1 in-process and fails
// instantly, keeping the test hermetic). Three defects cooperated pre-fix:
//
//  1. updateNetworkPolicyStatus was dead code - the batch loop logged the
//     per-namespace failure and dropped it, so status.networkPolicies never
//     carried the error (phase 1 asserts the entry appears).
//  2. A pointer-vs-copy append bug would have silently dropped ErrorMessage
//     for first-time namespaces even if the function had been called
//     (phase 1's ErrorMessage assertion covers the persisted value).
//  3. The event-driven filter skipped every namespace with a status entry
//     and the periodic pass only considers "pr-merged" entries - so a naive
//     error entry would have made the failure permanent. Phase 2 bumps the
//     ConfigMap and proves the failed namespace is re-processed (clone
//     attempt counter grows) despite its existing error entry.
//
// Retry cadence note: the main reconcile skip guard (unchanged ConfigMap
// version + role mapping) gates ALL NetworkPolicy processing, so retries
// happen on the passes that run at all - same cadence as the pre-fix
// behavior for entry-less failed namespaces.

import (
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
	"github.com/permission-binder-operator/operator/internal/controller/networkpolicy"
)

const (
	npErrPBName   = "test-pb-networkpolicy-git-failure"
	npErrCMName   = "np-git-failure-config"
	npErrSecret   = "github-gitops-credentials-invalid"
	npErrTargetNS = "test-git-failure"
)

// createNPGitFailureFixtures mirrors the e2e test 53 setup: invalid git
// credentials Secret, a whitelist ConfigMap, and a PermissionBinder with
// NetworkPolicy enabled against an unreachable repository.
func createNPGitFailureFixtures(t *testing.T, pe *poisonEnv) {
	t.Helper()

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: npErrSecret, Namespace: poisonOpNS},
		StringData: map[string]string{
			"token":    "invalid-token",
			"username": "invalid-user",
			"email":    "invalid@example.com",
		},
	}
	if err := pe.direct.Create(pe.ctx, secret); err != nil {
		t.Fatal(err)
	}

	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: npErrCMName, Namespace: poisonOpNS},
		Data: map[string]string{
			"whitelist.txt": "CN=COMPANY-K8S-" + npErrTargetNS + "-engineer,OU=Openshift,DC=example,DC=com",
		},
	}
	if err := pe.direct.Create(pe.ctx, cm); err != nil {
		t.Fatal(err)
	}

	pb := &permissionv1.PermissionBinder{
		ObjectMeta: metav1.ObjectMeta{Name: npErrPBName, Namespace: poisonOpNS},
		Spec: permissionv1.PermissionBinderSpec{
			ConfigMapName:      npErrCMName,
			ConfigMapNamespace: poisonOpNS,
			Prefixes:           []string{"COMPANY-K8S"},
			RoleMapping:        map[string]string{"engineer": "edit", "viewer": "view"},
			NetworkPolicy: &permissionv1.NetworkPolicySpec{
				Enabled:        true,
				TemplateDir:    "networkpolicies/templates",
				BackupExisting: true,
				GitRepository: &permissionv1.GitRepositorySpec{
					Provider:    "github",
					URL:         "http://127.0.0.1:1/tests/does-not-exist.git",
					BaseBranch:  "main",
					ClusterName: "DEV-cluster",
					CredentialsSecretRef: &permissionv1.LdapSecretReference{
						Name:      npErrSecret,
						Namespace: poisonOpNS,
					},
				},
			},
		},
	}
	if err := pe.direct.Create(pe.ctx, pb); err != nil {
		t.Fatal(err)
	}
}

func getNPErrorEntry(t *testing.T, pe *poisonEnv) *permissionv1.NetworkPolicyStatus {
	t.Helper()
	var pb permissionv1.PermissionBinder
	if err := pe.direct.Get(pe.ctx,
		types.NamespacedName{Name: npErrPBName, Namespace: poisonOpNS}, &pb); err != nil {
		return nil
	}
	for i := range pb.Status.NetworkPolicies {
		if pb.Status.NetworkPolicies[i].Namespace == npErrTargetNS {
			return &pb.Status.NetworkPolicies[i]
		}
	}
	return nil
}

// TestNetworkPolicyGitFailureSurfacesInStatus is the in-repo acceptance test
// for issue #54 (e2e test 53 is the live acceptance test).
func TestNetworkPolicyGitFailureSurfacesInStatus(t *testing.T) {
	if testing.Short() {
		t.Skip("envtest-based, skipped in -short mode")
	}
	pe := startPoisonEnv(t, nil)
	createNPGitFailureFixtures(t, pe)

	// Phase 1 (defects 1+2): the git failure must surface as an "error"
	// entry carrying the sanitized error message - the e2e test 53
	// assertion that failed pre-fix.
	waitForPoison(t, 90*time.Second, "error entry in status.networkPolicies", func() bool {
		e := getNPErrorEntry(t, pe)
		return e != nil && e.State == "error" && e.ErrorMessage != ""
	})
	entry := getNPErrorEntry(t, pe)
	if !strings.Contains(entry.ErrorMessage, "failed to clone repository") {
		t.Errorf("errorMessage should carry the clone failure, got: %q", entry.ErrorMessage)
	}

	// Phase 2 (defect 3): the recorded error entry must not block retries.
	// Bump the ConfigMap (new role for the same namespace) so a reconcile
	// passes the skip guard, and prove another clone attempt happens for the
	// namespace despite its existing status entry.
	cloneErrors := func() float64 {
		return testutil.ToFloat64(
			networkpolicy.NetworkPolicyGitOperationsTotal.WithLabelValues("clone", "error"))
	}
	before := cloneErrors()

	var cm corev1.ConfigMap
	if err := pe.direct.Get(pe.ctx,
		types.NamespacedName{Name: npErrCMName, Namespace: poisonOpNS}, &cm); err != nil {
		t.Fatal(err)
	}
	cm.Data["whitelist.txt"] += "\nCN=COMPANY-K8S-" + npErrTargetNS + "-viewer,OU=Openshift,DC=example,DC=com"
	if err := pe.direct.Update(pe.ctx, &cm); err != nil {
		t.Fatal(err)
	}

	waitForPoison(t, 90*time.Second, "retry of the failed namespace (clone attempt counter)", func() bool {
		return cloneErrors() > before
	})

	// Still failing, so the entry must still be there and still say "error"
	entry = getNPErrorEntry(t, pe)
	if entry == nil || entry.State != "error" || entry.ErrorMessage == "" {
		t.Fatalf("error entry must survive a failed retry, got: %+v", entry)
	}
}
