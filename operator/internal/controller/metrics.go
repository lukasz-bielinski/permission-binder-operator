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

package controller

import (
	"context"
	"fmt"

	"github.com/prometheus/client_golang/prometheus"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/selection"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/metrics"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
	networkpolicy "github.com/permission-binder-operator/operator/internal/controller/networkpolicy"
)

// Prometheus metrics for production environment monitoring
var (
	// Counter for missing ClusterRoles (security critical)
	missingClusterRoleTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "permission_binder_missing_clusterrole_total",
			Help: "Total number of times a ClusterRole was not found (security critical)",
		},
		[]string{"clusterrole", "namespace"},
	)

	// Gauge for orphaned resources (recovery tracking)
	orphanedResourcesTotal = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "permission_binder_orphaned_resources_total",
			Help: "Current number of orphaned resources (RoleBindings and Namespaces)",
		},
		[]string{"resource_type"},
	)

	// Counter for resource adoption events (recovery success)
	adoptionEventsTotal = prometheus.NewCounter(
		prometheus.CounterOpts{
			Name: "permission_binder_adoption_events_total",
			Help: "Total number of orphaned resource adoptions (automatic recovery)",
		},
	)

	// Gauge for managed RoleBindings
	managedRoleBindingsTotal = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "permission_binder_managed_rolebindings_total",
			Help: "Current number of RoleBindings managed by the operator",
		},
	)

	// Gauge for managed Namespaces
	managedNamespacesTotal = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "permission_binder_managed_namespaces_total",
			Help: "Current number of Namespaces managed by the operator",
		},
	)

	// Counter for ConfigMap processing
	configMapEntriesProcessed = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "permission_binder_configmap_entries_processed_total",
			Help: "Total number of ConfigMap entries processed",
		},
		[]string{"status"}, // success, error, excluded
	)

	// Counter for LDAP group operations
	ldapGroupOperationsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "permission_binder_ldap_group_operations_total",
			Help: "Total number of LDAP group operations (create, exists, error)",
		},
		[]string{"operation"}, // created, exists, error
	)

	// Counter for LDAP connection attempts
	ldapConnectionsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "permission_binder_ldap_connections_total",
			Help: "Total number of LDAP connection attempts",
		},
		[]string{"status"}, // success, error
	)

	// Counter for ServiceAccount creations
	serviceAccountsCreated = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "permission_binder_service_accounts_created_total",
			Help: "Total number of ServiceAccounts created",
		},
		[]string{"namespace", "sa_type"}, // namespace, deploy/runtime/etc
	)

	// Gauge for managed ServiceAccounts
	managedServiceAccountsTotal = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "permission_binder_managed_service_accounts_total",
			Help: "Current number of ServiceAccounts managed by the operator",
		},
	)
)

func init() {
	// Register custom metrics with Prometheus
	metrics.Registry.MustRegister(
		missingClusterRoleTotal,
		orphanedResourcesTotal,
		adoptionEventsTotal,
		ldapGroupOperationsTotal,
		ldapConnectionsTotal,
		managedRoleBindingsTotal,
		managedNamespacesTotal,
		managedServiceAccountsTotal,
		serviceAccountsCreated,
		configMapEntriesProcessed,
		// NetworkPolicy metrics (from network_policy_helper.go)
		networkpolicy.NetworkPolicyPRsCreatedTotal,
		networkpolicy.NetworkPolicyPRCreationErrorsTotal,
		networkpolicy.NetworkPolicyTemplateValidationErrorsTotal,
		networkpolicy.NetworkPolicyMultipleCRsWarningTotal,
	)
}

// updateMetrics updates Prometheus metrics for monitoring and alerting
func (r *PermissionBinderReconciler) updateMetrics(ctx context.Context, permissionBinder *permissionv1.PermissionBinder) error {
	// Update managed RoleBindings count
	roleBindings, err := r.getManagedRoleBindings(ctx, permissionBinder)
	if err != nil {
		return fmt.Errorf("failed to get managed RoleBindings: %w", err)
	}
	managedRoleBindingsTotal.Set(float64(len(roleBindings)))

	// Update managed Namespaces count
	namespaces, err := r.getManagedNamespaces(ctx, permissionBinder)
	if err != nil {
		return fmt.Errorf("failed to get managed Namespaces: %w", err)
	}
	managedNamespacesTotal.Set(float64(len(namespaces)))

	// Update orphaned resources count
	orphanedRB := 0
	orphanedNS := 0

	for _, rb := range roleBindings {
		if rb.Annotations != nil && rb.Annotations["permission-binder.io/orphaned-at"] != "" {
			orphanedRB++
		}
	}
	orphanedResourcesTotal.WithLabelValues("rolebinding").Set(float64(orphanedRB))

	// Check orphaned namespaces
	var nsList corev1.NamespaceList
	selector := labels.NewSelector()
	req, err := labels.NewRequirement(LabelManagedBy, selection.Equals, []string{ManagedByValue})
	if err == nil {
		selector = selector.Add(*req)
		if err := r.List(ctx, &nsList, &client.ListOptions{LabelSelector: selector}); err == nil {
			for _, ns := range nsList.Items {
				if ns.Annotations != nil && ns.Annotations["permission-binder.io/orphaned-at"] != "" {
					orphanedNS++
				}
			}
		}
	}
	orphanedResourcesTotal.WithLabelValues("namespace").Set(float64(orphanedNS))

	return nil
}

