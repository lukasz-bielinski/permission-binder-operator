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

// Regression tests for issue #54: NetworkPolicy git failures never reached CR
// status. updateNetworkPolicyStatus was dead code with a pointer-vs-copy bug
// that silently dropped ErrorMessage/CreatedAt for first-time namespaces, and
// a naive call would have made failures permanent because the event-driven
// filter skipped every namespace with a status entry.

import (
	"context"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// setupStatusFakeClient builds a fake client with the PermissionBinder status
// subresource enabled, so Status().Update exercises the same path as a real
// apiserver.
func setupStatusFakeClient(objs ...client.Object) ReconcilerInterface {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)
	_ = networkingv1.AddToScheme(scheme)
	_ = permissionv1.AddToScheme(scheme)

	return fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(objs...).
		WithStatusSubresource(&permissionv1.PermissionBinder{}).
		Build()
}

func newStatusTestBinder(entries ...permissionv1.NetworkPolicyStatus) *permissionv1.PermissionBinder {
	return &permissionv1.PermissionBinder{
		ObjectMeta: metav1.ObjectMeta{Name: "test-binder", Namespace: "default"},
		Status: permissionv1.PermissionBinderStatus{
			NetworkPolicies: entries,
		},
	}
}

func getPersistedBinder(t *testing.T, r ReconcilerInterface) *permissionv1.PermissionBinder {
	t.Helper()
	var binder permissionv1.PermissionBinder
	require.NoError(t, r.Get(context.Background(),
		types.NamespacedName{Name: "test-binder", Namespace: "default"}, &binder))
	return &binder
}

// TestUpdateNetworkPolicyStatus_NewEntryPersistsFields is the direct
// regression test for the pointer-vs-copy bug: the pre-fix code appended a
// copy and then set ErrorMessage on a dangling local, so a NEW namespace
// entry reached the cluster without the error message.
func TestUpdateNetworkPolicyStatus_NewEntryPersistsFields(t *testing.T) {
	binder := newStatusTestBinder()
	r := setupStatusFakeClient(binder)

	err := updateNetworkPolicyStatus(r, context.Background(), binder,
		"test-git-failure", "error", "failed to clone repository: connection refused")
	require.NoError(t, err)

	persisted := getPersistedBinder(t, r)
	require.Len(t, persisted.Status.NetworkPolicies, 1)
	entry := persisted.Status.NetworkPolicies[0]
	assert.Equal(t, "test-git-failure", entry.Namespace)
	assert.Equal(t, "error", entry.State)
	assert.Equal(t, "failed to clone repository: connection refused", entry.ErrorMessage,
		"ErrorMessage must land on the appended slice element, not a local copy")

	// The passed-in binder must reflect the persisted state too
	inMemory := getNetworkPolicyStatus(binder, "test-git-failure")
	require.NotNil(t, inMemory)
	assert.Equal(t, "error", inMemory.State)
	assert.Equal(t, "failed to clone repository: connection refused", inMemory.ErrorMessage)
}

// TestUpdateNetworkPolicyStatus_NewEntryStampsCreatedAt covers the second
// field the pointer-vs-copy bug dropped for first-time namespaces.
func TestUpdateNetworkPolicyStatus_NewEntryStampsCreatedAt(t *testing.T) {
	binder := newStatusTestBinder()
	r := setupStatusFakeClient(binder)

	err := updateNetworkPolicyStatus(r, context.Background(), binder, "some-ns", "pr-pending", "")
	require.NoError(t, err)

	persisted := getPersistedBinder(t, r)
	require.Len(t, persisted.Status.NetworkPolicies, 1)
	assert.Equal(t, "pr-pending", persisted.Status.NetworkPolicies[0].State)
	assert.NotEmpty(t, persisted.Status.NetworkPolicies[0].CreatedAt,
		"CreatedAt must be stamped on the persisted entry for pr-pending")
}

// TestUpdateNetworkPolicyStatus_ExistingEntryTransitionClearsError asserts the
// clear-on-success semantics: passing an empty errorMessage clears a
// previously recorded error instead of leaving it stale.
func TestUpdateNetworkPolicyStatus_ExistingEntryTransitionClearsError(t *testing.T) {
	binder := newStatusTestBinder(
		permissionv1.NetworkPolicyStatus{Namespace: "other-ns", State: "pr-merged"},
		permissionv1.NetworkPolicyStatus{Namespace: "failed-ns", State: "error", ErrorMessage: "boom"},
	)
	r := setupStatusFakeClient(binder)

	err := updateNetworkPolicyStatus(r, context.Background(), binder, "failed-ns", "pr-merged", "")
	require.NoError(t, err)

	persisted := getPersistedBinder(t, r)
	require.Len(t, persisted.Status.NetworkPolicies, 2)
	entry := getNetworkPolicyStatus(persisted, "failed-ns")
	require.NotNil(t, entry)
	assert.Equal(t, "pr-merged", entry.State)
	assert.Empty(t, entry.ErrorMessage, "transition to success must clear the stale error message")

	// Sibling entry untouched
	other := getNetworkPolicyStatus(persisted, "other-ns")
	require.NotNil(t, other)
	assert.Equal(t, "pr-merged", other.State)
}

// TestUpdateNetworkPolicyStatus_TruncatesLongMessage bounds what a verbose git
// error can push into the CR.
func TestUpdateNetworkPolicyStatus_TruncatesLongMessage(t *testing.T) {
	binder := newStatusTestBinder()
	r := setupStatusFakeClient(binder)

	err := updateNetworkPolicyStatus(r, context.Background(), binder,
		"some-ns", "error", strings.Repeat("x", 5000))
	require.NoError(t, err)

	persisted := getPersistedBinder(t, r)
	require.Len(t, persisted.Status.NetworkPolicies, 1)
	assert.Len(t, persisted.Status.NetworkPolicies[0].ErrorMessage, maxStatusErrorMessageLength)
}

// TestUpdateNetworkPolicyStatus_SanitizesMessage: the CR status is readable
// by a wider audience than the logs, so inline URL credentials (e.g. from a
// detectGitProvider error embedding the raw repo URL) must never land there.
func TestUpdateNetworkPolicyStatus_SanitizesMessage(t *testing.T) {
	binder := newStatusTestBinder()
	r := setupStatusFakeClient(binder)

	err := updateNetworkPolicyStatus(r, context.Background(), binder, "some-ns", "error",
		"cannot auto-detect git provider from URL: https://x:ghp_supersecret@git.corp/a/b.git")
	require.NoError(t, err)

	persisted := getPersistedBinder(t, r)
	require.Len(t, persisted.Status.NetworkPolicies, 1)
	msg := persisted.Status.NetworkPolicies[0].ErrorMessage
	assert.NotContains(t, msg, "ghp_supersecret")
	assert.Contains(t, msg, "://[REDACTED]:[REDACTED]@git.corp")
}

// TestUpdateNetworkPolicyStatus_TruncationIsRuneSafe: the 1KiB cap must not
// split a multi-byte UTF-8 rune (which would render as U+FFFD in consumers).
func TestUpdateNetworkPolicyStatus_TruncationIsRuneSafe(t *testing.T) {
	binder := newStatusTestBinder()
	r := setupStatusFakeClient(binder)

	// 2-byte rune spanning the 1024-byte boundary
	msg := strings.Repeat("x", maxStatusErrorMessageLength-1) + "żZZZZ"
	err := updateNetworkPolicyStatus(r, context.Background(), binder, "some-ns", "error", msg)
	require.NoError(t, err)

	persisted := getPersistedBinder(t, r)
	require.Len(t, persisted.Status.NetworkPolicies, 1)
	stored := persisted.Status.NetworkPolicies[0].ErrorMessage
	assert.True(t, utf8.ValidString(stored), "truncated message must remain valid UTF-8")
	assert.Len(t, stored, maxStatusErrorMessageLength-1, "the split rune must be dropped, not cut")
}

func TestIsRetryableNetworkPolicyState(t *testing.T) {
	tests := []struct {
		state     string
		retryable bool
	}{
		{"error", true},
		{"", true}, // defensive: unknown/empty entries must not wedge
		{"pr-created", false},
		{"pr-pending", false},
		{"pr-merged", false},
		{"pr-conflict", false},
		{"pr-stale", false},
		{"pr-removal", false},
		{"removed", false},
	}
	for _, tt := range tests {
		assert.Equal(t, tt.retryable, isRetryableNetworkPolicyState(tt.state), "state %q", tt.state)
	}
}

// TestClearNetworkPolicyStatusEntry_RemovesOnlyRetryableEntry asserts the
// recovery path drops the stale error entry and nothing else.
func TestClearNetworkPolicyStatusEntry_RemovesOnlyRetryableEntry(t *testing.T) {
	binder := newStatusTestBinder(
		permissionv1.NetworkPolicyStatus{Namespace: "other-ns", State: "pr-merged"},
		permissionv1.NetworkPolicyStatus{Namespace: "failed-ns", State: "error", ErrorMessage: "boom"},
	)
	r := setupStatusFakeClient(binder)

	err := clearNetworkPolicyStatusEntry(r, context.Background(), binder, "failed-ns")
	require.NoError(t, err)

	persisted := getPersistedBinder(t, r)
	require.Len(t, persisted.Status.NetworkPolicies, 1)
	assert.Equal(t, "other-ns", persisted.Status.NetworkPolicies[0].Namespace)
	assert.Nil(t, getNetworkPolicyStatus(binder, "failed-ns"), "in-memory binder must reflect the removal")
}

// TestClearNetworkPolicyStatusEntry_LeavesNonRetryableEntry guards against
// clobbering a concurrent success write: only entries still in a retryable
// state are removed.
func TestClearNetworkPolicyStatusEntry_LeavesNonRetryableEntry(t *testing.T) {
	binder := newStatusTestBinder(
		permissionv1.NetworkPolicyStatus{Namespace: "some-ns", State: "pr-created"},
	)
	r := setupStatusFakeClient(binder)

	err := clearNetworkPolicyStatusEntry(r, context.Background(), binder, "some-ns")
	require.NoError(t, err)

	persisted := getPersistedBinder(t, r)
	require.Len(t, persisted.Status.NetworkPolicies, 1)
	assert.Equal(t, "pr-created", persisted.Status.NetworkPolicies[0].State)
}

func TestClearNetworkPolicyStatusEntry_MissingEntryIsNoop(t *testing.T) {
	binder := newStatusTestBinder()
	r := setupStatusFakeClient(binder)

	assert.NoError(t, clearNetworkPolicyStatusEntry(r, context.Background(), binder, "absent-ns"))
}

// TestUpdateNetworkPolicyStatusWithPR_ClearsErrorMessage asserts the success
// transition for a namespace that previously failed: the PR fields replace the
// error entry and the stale message is cleared.
func TestUpdateNetworkPolicyStatusWithPR_ClearsErrorMessage(t *testing.T) {
	binder := newStatusTestBinder(
		permissionv1.NetworkPolicyStatus{Namespace: "failed-ns", State: "error", ErrorMessage: "boom"},
	)
	r := setupStatusFakeClient(binder)

	err := updateNetworkPolicyStatusWithPR(r, context.Background(), binder,
		"failed-ns", 42, "networkpolicy/DEV-cluster-failed-ns", "https://example.com/pr/42", "pr-created")
	require.NoError(t, err)

	persisted := getPersistedBinder(t, r)
	entry := getNetworkPolicyStatus(persisted, "failed-ns")
	require.NotNil(t, entry)
	assert.Equal(t, "pr-created", entry.State)
	assert.Empty(t, entry.ErrorMessage, "successful PR creation must clear the previous error")
	require.NotNil(t, entry.PRNumber)
	assert.Equal(t, 42, *entry.PRNumber)
	assert.NotEmpty(t, entry.CreatedAt)
}
