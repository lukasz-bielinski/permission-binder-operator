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

package networkpolicy

// Regression tests for issue #54: the event-driven batch loop must record
// per-namespace git failures in status.networkPolicies, keep failed
// namespaces retryable (the periodic pass only considers "pr-merged"
// entries), and clean up after a successful retry.

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// fastBatchSpec keeps the loop's rate-limiting sleeps out of unit tests.
func fastBatchSpec() *permissionv1.NetworkPolicySpec {
	return &permissionv1.NetworkPolicySpec{
		Enabled: true,
		BatchProcessing: &permissionv1.BatchProcessingSpec{
			BatchSize:              5,
			SleepBetweenNamespaces: "1ms",
			SleepBetweenBatches:    "1ms",
		},
	}
}

// stubProcessNamespace swaps the per-namespace processing step for the test's
// duration and restores the real implementation afterwards.
func stubProcessNamespace(t *testing.T, fn func(ctx context.Context, r ReconcilerInterface, permissionBinder *permissionv1.PermissionBinder, namespace string) error) {
	t.Helper()
	orig := processNamespaceFn
	processNamespaceFn = fn
	t.Cleanup(func() { processNamespaceFn = orig })
}

func TestSelectNamespacesForEventDrivenProcessing(t *testing.T) {
	binder := newStatusTestBinder(
		permissionv1.NetworkPolicyStatus{Namespace: "ns-error", State: "error", ErrorMessage: "boom"},
		permissionv1.NetworkPolicyStatus{Namespace: "ns-merged", State: "pr-merged"},
		permissionv1.NetworkPolicyStatus{Namespace: "ns-pending", State: "pr-pending"},
		permissionv1.NetworkPolicyStatus{Namespace: "ns-empty-state", State: ""},
	)

	selected := selectNamespacesForEventDrivenProcessing(context.Background(), binder,
		[]string{"ns-new", "ns-error", "ns-merged", "ns-pending", "ns-empty-state"})

	// ns-new: never processed; ns-error/ns-empty-state: retryable - the
	// pre-fix filter skipped ANY namespace with a status entry, which would
	// have made a recorded failure permanent.
	assert.Equal(t, []string{"ns-new", "ns-error", "ns-empty-state"}, selected)
}

// TestProcessNetworkPoliciesForNamespaces_RecordsFailureInStatus asserts
// defect 1 end-to-end at the batch level: a per-namespace failure lands in
// status.networkPolicies as an "error" entry instead of being dropped.
func TestProcessNetworkPoliciesForNamespaces_RecordsFailureInStatus(t *testing.T) {
	binder := newStatusTestBinder(
		permissionv1.NetworkPolicyStatus{Namespace: "ns-merged", State: "pr-merged"},
	)
	binder.Spec.NetworkPolicy = fastBatchSpec()
	r := setupStatusFakeClient(binder)

	var processed []string
	stubProcessNamespace(t, func(_ context.Context, _ ReconcilerInterface, _ *permissionv1.PermissionBinder, namespace string) error {
		processed = append(processed, namespace)
		return errors.New("failed to clone repository: connection refused")
	})

	err := ProcessNetworkPoliciesForNamespaces(context.Background(), r, binder,
		[]string{"failing-ns", "ns-merged"})
	require.NoError(t, err, "per-namespace failures must not abort the batch")

	assert.Equal(t, []string{"failing-ns"}, processed, "pr-merged namespace must be skipped")

	persisted := getPersistedBinder(t, r)
	entry := getNetworkPolicyStatus(persisted, "failing-ns")
	require.NotNil(t, entry, "failure must be recorded in status.networkPolicies")
	assert.Equal(t, "error", entry.State)
	assert.Equal(t, "failed to clone repository: connection refused", entry.ErrorMessage)
}

// TestProcessNetworkPoliciesForNamespaces_RetriesAndDropsStaleEntryOnRecovery
// covers defect 3 plus the recovery path: a recorded failure is re-processed
// on the next pass, and a successful retry with nothing left to do removes
// the stale error entry.
func TestProcessNetworkPoliciesForNamespaces_RetriesAndDropsStaleEntryOnRecovery(t *testing.T) {
	binder := newStatusTestBinder()
	binder.Spec.NetworkPolicy = fastBatchSpec()
	r := setupStatusFakeClient(binder)

	calls := 0
	stubProcessNamespace(t, func(_ context.Context, _ ReconcilerInterface, _ *permissionv1.PermissionBinder, _ string) error {
		calls++
		if calls == 1 {
			return errors.New("transient git outage")
		}
		return nil // recovered, nothing left to do (no PR created)
	})

	// Pass 1: failure recorded
	require.NoError(t, ProcessNetworkPoliciesForNamespaces(context.Background(), r, binder, []string{"flaky-ns"}))
	entry := getNetworkPolicyStatus(getPersistedBinder(t, r), "flaky-ns")
	require.NotNil(t, entry)
	require.Equal(t, "error", entry.State)

	// Pass 2: the error entry must NOT block re-processing (pre-fix filter
	// semantics would have skipped it forever), and the successful no-op
	// retry must drop the stale entry.
	require.NoError(t, ProcessNetworkPoliciesForNamespaces(context.Background(), r, binder, []string{"flaky-ns"}))
	assert.Equal(t, 2, calls, "namespace with an error entry must be retried")
	assert.Nil(t, getNetworkPolicyStatus(getPersistedBinder(t, r), "flaky-ns"),
		"stale error entry must be removed after a successful no-op retry")
}

// TestProcessNetworkPoliciesForNamespaces_RetryThatCreatesPRReplacesEntry
// asserts the other recovery shape: a retry that creates a PR replaces the
// error entry (via updateNetworkPolicyStatusWithPR) and the batch loop leaves
// the new entry alone.
func TestProcessNetworkPoliciesForNamespaces_RetryThatCreatesPRReplacesEntry(t *testing.T) {
	binder := newStatusTestBinder(
		permissionv1.NetworkPolicyStatus{Namespace: "flaky-ns", State: "error", ErrorMessage: "previous failure"},
	)
	binder.Spec.NetworkPolicy = fastBatchSpec()
	r := setupStatusFakeClient(binder)

	stubProcessNamespace(t, func(ctx context.Context, r ReconcilerInterface, pb *permissionv1.PermissionBinder, namespace string) error {
		// Mirror what ProcessNetworkPolicyForNamespace does on success
		return updateNetworkPolicyStatusWithPR(r, ctx, pb, namespace, 7, "networkpolicy/DEV-cluster-"+namespace, "https://example.com/pr/7", "pr-created")
	})

	require.NoError(t, ProcessNetworkPoliciesForNamespaces(context.Background(), r, binder, []string{"flaky-ns"}))

	entry := getNetworkPolicyStatus(getPersistedBinder(t, r), "flaky-ns")
	require.NotNil(t, entry, "the pr-created entry must survive the batch loop's cleanup step")
	assert.Equal(t, "pr-created", entry.State)
	assert.Empty(t, entry.ErrorMessage)
	require.NotNil(t, entry.PRNumber)
	assert.Equal(t, 7, *entry.PRNumber)
}

// TestProcessNetworkPoliciesForNamespaces_CloneFailureEndToEnd exercises the
// REAL ProcessNetworkPolicyForNamespace (no stub) against an unreachable git
// remote - the exact e2e test 53 scenario (invalid credentials/unreachable
// repo) - and asserts the failure surfaces in status. Hermetic: the clone
// dials 127.0.0.1:1 in-process and fails instantly with connection refused.
func TestProcessNetworkPoliciesForNamespaces_CloneFailureEndToEnd(t *testing.T) {
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "git-creds", Namespace: "default"},
		Data: map[string][]byte{
			"token":    []byte("invalid-token"),
			"username": []byte("invalid-user"),
			"email":    []byte("invalid@example.com"),
		},
	}
	binder := newStatusTestBinder()
	binder.Spec.NetworkPolicy = &permissionv1.NetworkPolicySpec{
		Enabled:     true,
		TemplateDir: "networkpolicies/templates",
		GitRepository: &permissionv1.GitRepositorySpec{
			Provider:    "github",
			URL:         "http://127.0.0.1:1/tests/does-not-exist.git",
			BaseBranch:  "main",
			ClusterName: "DEV-cluster",
			CredentialsSecretRef: &permissionv1.LdapSecretReference{
				Name:      "git-creds",
				Namespace: "default",
			},
		},
		BatchProcessing: &permissionv1.BatchProcessingSpec{
			BatchSize:              5,
			SleepBetweenNamespaces: "1ms",
			SleepBetweenBatches:    "1ms",
		},
	}
	r := setupStatusFakeClient(binder, secret)

	require.NoError(t, ProcessNetworkPoliciesForNamespaces(context.Background(), r, binder, []string{"test-git-failure"}))

	persisted := getPersistedBinder(t, r)
	entry := getNetworkPolicyStatus(persisted, "test-git-failure")
	require.NotNil(t, entry, "clone failure must be recorded in status.networkPolicies")
	assert.Equal(t, "error", entry.State)
	assert.Contains(t, entry.ErrorMessage, "failed to clone repository")
	assert.Equal(t, 1, strings.Count(entry.ErrorMessage, "failed to clone repository"),
		"the clone error must not be double-prefixed by re-wrapping")
}
