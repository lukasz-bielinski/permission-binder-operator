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

// Note: This file has been refactored into specialized modules for better organization:
//
// - network_policy_constants.go: Constants, types, and Prometheus metrics
// - network_policy_utils.go: Utility functions (detectGitProvider, getAPIBaseURL,
//   extractWorkspaceFromURL, isNamespaceExcluded, getNetworkPolicyName, etc.)
// - network_policy_git.go: Git operations (clone, commit, push, PR operations, branch management)
// - network_policy_template.go: Template processing (read, validate, process templates)
// - network_policy_drift.go: Drift detection and NetworkPolicy comparison
// - network_policy_status.go: Status management and tracking
// - network_policy_kustomization.go: Kustomization.yaml management
// - network_policy_reconciliation.go: Main reconciliation logic (processNetworkPoliciesForNamespaces,
//   periodicNetworkPolicyReconciliation, processRemovedNamespaces, etc.)
//
// All functions have been moved to the appropriate specialized modules. This file is kept
// for reference and to maintain backward compatibility during migration.
