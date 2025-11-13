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
// - reconciliation_validation.go: CheckMultiplePermissionBinders
// - reconciliation_single.go: ProcessNetworkPolicyForNamespace (single namespace processing)
// - reconciliation_batch.go: ProcessNetworkPoliciesForNamespaces (batch processing)
// - reconciliation_periodic.go: PeriodicNetworkPolicyReconciliation, checkTemplateChanges
// - reconciliation_cleanup.go: ProcessRemovedNamespaces
//
// All functions have been moved to the appropriate specialized modules. This file is kept
// for reference and to maintain backward compatibility during migration.
