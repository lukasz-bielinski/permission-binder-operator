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

import (
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

const (
	// NetworkPolicy annotation keys used to track template metadata on NetworkPolicy resources.

	// AnnotationTemplate stores the template filename used to generate the NetworkPolicy.
	AnnotationTemplate = "network-policy.permission-binder.io/template"

	// AnnotationTemplateVersion stores the Git commit/version of the template.
	AnnotationTemplateVersion = "network-policy.permission-binder.io/template-version"

	// AnnotationTemplatePath stores the full path to the template in the Git repository.
	AnnotationTemplatePath = "network-policy.permission-binder.io/template-path"

	// AnnotationSource indicates the source of the NetworkPolicy (e.g., "template", "backup").
	AnnotationSource = "network-policy.permission-binder.io/source"

	// maxStatusErrorMessageLength bounds the error message stored in
	// NetworkPolicyStatus.ErrorMessage (git errors can be long)
	maxStatusErrorMessageLength = 1024

	// Default values
	defaultBatchSize              = 5
	defaultSleepBetweenNamespaces = 3 * time.Second
	defaultSleepBetweenBatches    = 60 * time.Second
	defaultReconciliationInterval = 1 * time.Hour
	defaultStatusRetentionDays    = 30
	defaultStalePRThreshold       = 30 * 24 * time.Hour

	// gitRemoteOrigin is the conventional remote name used for all go-git operations.
	gitRemoteOrigin = "origin"

	// NetworkPolicy status state values recorded in PermissionBinder.Status.NetworkPolicies.
	statePRCreated = "pr-created"
	statePRMerged  = "pr-merged"
	statePRPending = "pr-pending"
	stateRemoved   = "removed"

	// metricLabelCluster is the Prometheus label name for the cluster dimension.
	metricLabelCluster = "cluster"

	// gitBotUsername is the default git author/committer identity used for commits.
	gitBotUsername = "permission-binder-operator"
)

// Git credentials structure
type gitCredentials struct {
	token    string
	username string
	email    string
}

// pullRequest structure for different providers (used in Git operations)
type pullRequest struct {
	Number int
	State  string // OPEN, MERGED, DECLINED, etc.
	URL    string
	Branch string
}

// Prometheus metrics for NetworkPolicy operations.
//
// These metrics are exported for registration in the operator's main initialization.
// They provide observability into NetworkPolicy management operations.
var (
	// NetworkPolicyPRsCreatedTotal counts the total number of NetworkPolicy Pull Requests created.
	// Labels: cluster, namespace, variant (A/B/C)
	NetworkPolicyPRsCreatedTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "permission_binder_networkpolicy_prs_created_total",
			Help: "Total number of NetworkPolicy PRs created",
		},
		[]string{metricLabelCluster, "namespace", "variant"},
	)

	// NetworkPolicyPRCreationErrorsTotal counts the total number of PR creation errors.
	// Labels: cluster, namespace, variant (A/B/C), error_type
	NetworkPolicyPRCreationErrorsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "permission_binder_networkpolicy_pr_creation_errors_total",
			Help: "Total number of NetworkPolicy PR creation errors",
		},
		[]string{metricLabelCluster, "namespace", "variant", "error_type"},
	)

	// NetworkPolicyGitOperationsTotal counts Git operations (clone/push) by outcome.
	// Labels: operation, status (success/error)
	NetworkPolicyGitOperationsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "permission_binder_networkpolicy_git_operations_total",
			Help: "Total number of Git operations for NetworkPolicy",
		},
		[]string{"operation", "status"},
	)

	// NetworkPolicyTemplateValidationErrorsTotal counts template validation errors.
	// Labels: cluster, template
	NetworkPolicyTemplateValidationErrorsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "permission_binder_networkpolicy_template_validation_errors_total",
			Help: "Total number of NetworkPolicy template validation errors",
		},
		[]string{metricLabelCluster, "template"},
	)

	// NetworkPolicyMultipleCRsWarningTotal counts warnings about multiple PermissionBinder CRs
	// with NetworkPolicy enabled (should be only one).
	NetworkPolicyMultipleCRsWarningTotal = prometheus.NewCounter(
		prometheus.CounterOpts{
			Name: "permission_binder_multiple_crs_networkpolicy_warning_total",
			Help: "Total number of warnings about multiple PermissionBinder CRs with NetworkPolicy enabled",
		},
	)
)

// Metrics are registered in permissionbinder_controller.go init() function
