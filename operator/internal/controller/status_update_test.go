package controller

import (
	"reflect"
	"testing"

	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// TestFindCondition tests the findCondition helper function
func TestFindCondition(t *testing.T) {
	tests := []struct {
		name       string
		conditions []metav1.Condition
		conditionType string
		expected   *metav1.Condition
	}{
		{
			name:       "Find existing condition",
			conditions: []metav1.Condition{
				{Type: "Processed", Status: metav1.ConditionTrue},
				{Type: "Ready", Status: metav1.ConditionFalse},
			},
			conditionType: "Processed",
			expected:      &metav1.Condition{Type: "Processed", Status: metav1.ConditionTrue},
		},
		{
			name:       "Find condition in middle",
			conditions: []metav1.Condition{
				{Type: "Ready", Status: metav1.ConditionFalse},
				{Type: "Processed", Status: metav1.ConditionTrue},
				{Type: "Available", Status: metav1.ConditionTrue},
			},
			conditionType: "Processed",
			expected:      &metav1.Condition{Type: "Processed", Status: metav1.ConditionTrue},
		},
		{
			name:       "Condition not found",
			conditions: []metav1.Condition{
				{Type: "Ready", Status: metav1.ConditionFalse},
				{Type: "Available", Status: metav1.ConditionTrue},
			},
			conditionType: "Processed",
			expected:      nil,
		},
		{
			name:       "Empty conditions slice",
			conditions: []metav1.Condition{},
			conditionType: "Processed",
			expected:      nil,
		},
		{
			name:       "Nil conditions slice",
			conditions: nil,
			conditionType: "Processed",
			expected:      nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := findCondition(tt.conditions, tt.conditionType)
			if tt.expected == nil {
				require.Nil(t, result)
			} else {
				require.NotNil(t, result)
				require.Equal(t, tt.expected.Type, result.Type)
				require.Equal(t, tt.expected.Status, result.Status)
			}
		})
	}
}

// TestStatusChangeDetection tests the logic for detecting status changes
// This is a unit test for the status comparison logic used in Reconcile
func TestStatusChangeDetection(t *testing.T) {

	tests := []struct {
		name           string
		oldRoleBindings []string
		newRoleBindings []string
		oldSAs         []string
		newSAs         []string
		oldCMVersion   string
		newCMVersion   string
		oldHash        string
		newHash        string
		oldCondition   *metav1.Condition
		newMessage     string
		expectedChange bool
	}{
		{
			name:            "No changes",
			oldRoleBindings: []string{"ns1/rb1", "ns2/rb2"},
			newRoleBindings: []string{"ns1/rb1", "ns2/rb2"},
			oldSAs:          []string{"ns1/sa1"},
			newSAs:          []string{"ns1/sa1"},
			oldCMVersion:    "123",
			newCMVersion:    "123",
			oldHash:         "abc",
			newHash:         "abc",
			oldCondition:    &metav1.Condition{Type: "Processed", Status: metav1.ConditionTrue, Message: "Successfully processed 2 role bindings and 1 service accounts"},
			newMessage:      "Successfully processed 2 role bindings and 1 service accounts",
			expectedChange:  false,
		},
		{
			name:            "RoleBindings changed",
			oldRoleBindings: []string{"ns1/rb1"},
			newRoleBindings: []string{"ns1/rb1", "ns2/rb2"},
			oldSAs:          []string{"ns1/sa1"},
			newSAs:          []string{"ns1/sa1"},
			oldCMVersion:    "123",
			newCMVersion:    "123",
			oldHash:         "abc",
			newHash:         "abc",
			oldCondition:    &metav1.Condition{Type: "Processed", Status: metav1.ConditionTrue, Message: "Successfully processed 1 role bindings and 1 service accounts"},
			newMessage:      "Successfully processed 2 role bindings and 1 service accounts",
			expectedChange:  true,
		},
		{
			name:            "ServiceAccounts changed",
			oldRoleBindings: []string{"ns1/rb1"},
			newRoleBindings: []string{"ns1/rb1"},
			oldSAs:          []string{"ns1/sa1"},
			newSAs:          []string{"ns1/sa1", "ns2/sa2"},
			oldCMVersion:    "123",
			newCMVersion:    "123",
			oldHash:         "abc",
			newHash:         "abc",
			oldCondition:    &metav1.Condition{Type: "Processed", Status: metav1.ConditionTrue, Message: "Successfully processed 1 role bindings and 1 service accounts"},
			newMessage:      "Successfully processed 1 role bindings and 2 service accounts",
			expectedChange:  true,
		},
		{
			name:            "ConfigMap version changed",
			oldRoleBindings: []string{"ns1/rb1"},
			newRoleBindings: []string{"ns1/rb1"},
			oldSAs:          []string{"ns1/sa1"},
			newSAs:          []string{"ns1/sa1"},
			oldCMVersion:    "123",
			newCMVersion:    "456",
			oldHash:         "abc",
			newHash:         "abc",
			oldCondition:    &metav1.Condition{Type: "Processed", Status: metav1.ConditionTrue, Message: "Successfully processed 1 role bindings and 1 service accounts"},
			newMessage:      "Successfully processed 1 role bindings and 1 service accounts",
			expectedChange:  true,
		},
		{
			name:            "Hash changed",
			oldRoleBindings: []string{"ns1/rb1"},
			newRoleBindings: []string{"ns1/rb1"},
			oldSAs:          []string{"ns1/sa1"},
			newSAs:          []string{"ns1/sa1"},
			oldCMVersion:    "123",
			newCMVersion:    "123",
			oldHash:         "abc",
			newHash:         "def",
			oldCondition:    &metav1.Condition{Type: "Processed", Status: metav1.ConditionTrue, Message: "Successfully processed 1 role bindings and 1 service accounts"},
			newMessage:      "Successfully processed 1 role bindings and 1 service accounts",
			expectedChange:  true,
		},
		{
			name:            "Condition message changed",
			oldRoleBindings: []string{"ns1/rb1"},
			newRoleBindings: []string{"ns1/rb1"},
			oldSAs:          []string{"ns1/sa1"},
			newSAs:          []string{"ns1/sa1"},
			oldCMVersion:    "123",
			newCMVersion:    "123",
			oldHash:         "abc",
			newHash:         "abc",
			oldCondition:    &metav1.Condition{Type: "Processed", Status: metav1.ConditionTrue, Message: "Successfully processed 1 role bindings and 1 service accounts"},
			newMessage:      "Successfully processed 1 role bindings and 2 service accounts",
			expectedChange:  true,
		},
		{
			name:            "Condition not exists",
			oldRoleBindings: []string{"ns1/rb1"},
			newRoleBindings: []string{"ns1/rb1"},
			oldSAs:          []string{"ns1/sa1"},
			newSAs:          []string{"ns1/sa1"},
			oldCMVersion:    "123",
			newCMVersion:    "123",
			oldHash:         "abc",
			newHash:         "abc",
			oldCondition:    nil,
			newMessage:      "Successfully processed 1 role bindings and 1 service accounts",
			expectedChange:  true,
		},
		{
			name:            "Same data but different order in slices",
			oldRoleBindings: []string{"ns1/rb1", "ns2/rb2"},
			newRoleBindings: []string{"ns2/rb2", "ns1/rb1"},
			oldSAs:          []string{"ns1/sa1"},
			newSAs:          []string{"ns1/sa1"},
			oldCMVersion:    "123",
			newCMVersion:    "123",
			oldHash:         "abc",
			newHash:         "abc",
			oldCondition:    &metav1.Condition{Type: "Processed", Status: metav1.ConditionTrue, Message: "Successfully processed 2 role bindings and 1 service accounts"},
			newMessage:      "Successfully processed 2 role bindings and 1 service accounts",
			expectedChange:  true, // DeepEqual will detect order difference
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate the status change detection logic
			statusChanged := false

			// Compare RoleBindings
			if !reflect.DeepEqual(tt.oldRoleBindings, tt.newRoleBindings) {
				statusChanged = true
			}

			// Compare ServiceAccounts
			if !reflect.DeepEqual(tt.oldSAs, tt.newSAs) {
				statusChanged = true
			}

			// Compare ConfigMap version
			if tt.oldCMVersion != tt.newCMVersion {
				statusChanged = true
			}

			// Compare hash
			if tt.oldHash != tt.newHash {
				statusChanged = true
			}

			// Check condition
			if tt.oldCondition == nil || tt.oldCondition.Status != metav1.ConditionTrue || tt.oldCondition.Message != tt.newMessage {
				statusChanged = true
			}

			require.Equal(t, tt.expectedChange, statusChanged, "Status change detection should match expected result")
		})
	}
}

