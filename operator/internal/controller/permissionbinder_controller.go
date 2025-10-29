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
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/selection"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

const (
	// Annotation keys
	AnnotationManagedBy        = "permission-binder.io/managed-by"
	AnnotationCreatedAt        = "permission-binder.io/created-at"
	AnnotationPermissionBinder = "permission-binder.io/permission-binder"

	// Label keys
	LabelManagedBy = "permission-binder.io/managed-by"

	// Values
	ManagedByValue = "permission-binder-operator"

	// Finalizer
	PermissionBinderFinalizer = "permission-binder.io/finalizer"
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
	)
}

// PermissionBinderReconciler reconciles a PermissionBinder object
type PermissionBinderReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=permission.permission-binder.io,resources=permissionbinders,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=permission.permission-binder.io,resources=permissionbinders/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=permission.permission-binder.io,resources=permissionbinders/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=configmaps,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=namespaces,verbs=get;list;watch;create
// +kubebuilder:rbac:groups="",resources=serviceaccounts,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=rbac.authorization.k8s.io,resources=rolebindings,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=rbac.authorization.k8s.io,resources=clusterroles,verbs=get;list;watch

// Reconcile is part of the main kubernetes reconciliation loop which aims to
// move the current state of the cluster closer to the desired state.
// TODO(user): Modify the Reconcile function to compare the state specified by
// the PermissionBinder object against the actual cluster state, and then
// perform operations to make the cluster state reflect the state specified by
// the user.
//
// For more details, check Reconcile and its Result here:
// - https://pkg.go.dev/sigs.k8s.io/controller-runtime@v0.19.0/pkg/reconcile
func (r *PermissionBinderReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// Fetch the PermissionBinder instance
	var permissionBinder permissionv1.PermissionBinder
	if err := r.Get(ctx, req.NamespacedName, &permissionBinder); err != nil {
		if errors.IsNotFound(err) {
			logger.Info("PermissionBinder resource not found. Ignoring since object must be deleted")
			return ctrl.Result{}, nil
		}
		logger.Error(err, "Failed to get PermissionBinder")
		return ctrl.Result{}, err
	}

	// Check if this is a deletion - clean up managed resources
	if !permissionBinder.DeletionTimestamp.IsZero() {
		// The object is being deleted
		if containsString(permissionBinder.Finalizers, PermissionBinderFinalizer) {
			// Run finalization logic
			logger.Info("PermissionBinder is being deleted, cleaning up managed resources")
			if err := r.cleanupManagedResources(ctx, &permissionBinder); err != nil {
				logger.Error(err, "Failed to cleanup managed resources")
				return ctrl.Result{}, err
			}

			// Remove finalizer to allow deletion
			permissionBinder.Finalizers = removeString(permissionBinder.Finalizers, PermissionBinderFinalizer)
			if err := r.Update(ctx, &permissionBinder); err != nil {
				logger.Error(err, "Failed to remove finalizer")
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, nil
	}

	// Add finalizer if not present
	if !containsString(permissionBinder.Finalizers, PermissionBinderFinalizer) {
		permissionBinder.Finalizers = append(permissionBinder.Finalizers, PermissionBinderFinalizer)
		if err := r.Update(ctx, &permissionBinder); err != nil {
			logger.Error(err, "Failed to add finalizer")
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	// Check if role mapping has changed
	roleMappingChanged := r.hasRoleMappingChanged(&permissionBinder)
	if roleMappingChanged {
		logger.Info("Role mapping has changed, reconciling all managed resources")
		if err := r.reconcileAllManagedResources(ctx, &permissionBinder); err != nil {
			logger.Error(err, "Failed to reconcile all managed resources")
			return ctrl.Result{}, err
		}
	}

	// Fetch the ConfigMap
	var configMap corev1.ConfigMap
	configMapKey := types.NamespacedName{
		Name:      permissionBinder.Spec.ConfigMapName,
		Namespace: permissionBinder.Spec.ConfigMapNamespace,
	}
	if err := r.Get(ctx, configMapKey, &configMap); err != nil {
		if errors.IsNotFound(err) {
			logger.Info("ConfigMap not found", "configMap", configMapKey)
			return ctrl.Result{RequeueAfter: time.Minute}, nil
		}
		logger.Error(err, "Failed to get ConfigMap", "configMap", configMapKey)
		return ctrl.Result{}, err
	}

	// Check if ConfigMap has changed
	configMapVersion := configMap.ResourceVersion
	if permissionBinder.Status.LastProcessedConfigMapVersion == configMapVersion && !roleMappingChanged {
		logger.Info("ConfigMap and role mapping have not changed, skipping reconciliation")
		return ctrl.Result{}, nil
	}

	// Process ConfigMap data
	result, err := r.processConfigMap(ctx, &permissionBinder, &configMap)
	if err != nil {
		logger.Error(err, "Failed to process ConfigMap")
		return ctrl.Result{}, err
	}

	// Update status
	permissionBinder.Status.ProcessedRoleBindings = result.ProcessedRoleBindings
	permissionBinder.Status.ProcessedServiceAccounts = result.ProcessedServiceAccounts
	permissionBinder.Status.LastProcessedConfigMapVersion = configMapVersion
	permissionBinder.Status.Conditions = []metav1.Condition{
		{
			Type:               "Processed",
			Status:             metav1.ConditionTrue,
			LastTransitionTime: metav1.Now(),
			Reason:             "ConfigMapProcessed",
			Message:            fmt.Sprintf("Successfully processed %d role bindings and %d service accounts", len(result.ProcessedRoleBindings), len(result.ProcessedServiceAccounts)),
		},
	}

	if err := r.Status().Update(ctx, &permissionBinder); err != nil {
		logger.Error(err, "Failed to update PermissionBinder status")
		return ctrl.Result{}, err
	}

	// Update Prometheus metrics for monitoring
	if err := r.updateMetrics(ctx, &permissionBinder); err != nil {
		logger.Error(err, "Failed to update metrics (non-fatal)")
		// Don't fail reconciliation on metrics error
	}

	logger.Info("Successfully processed ConfigMap", "roleBindings", len(processedRoleBindings))
	return ctrl.Result{}, nil
}

// processConfigMap processes the ConfigMap data and creates RoleBindings
// ProcessConfigMapResult holds the results of processing a ConfigMap
type ProcessConfigMapResult struct {
	ProcessedRoleBindings    []string
	ProcessedServiceAccounts []string
}

func (r *PermissionBinderReconciler) processConfigMap(ctx context.Context, permissionBinder *permissionv1.PermissionBinder, configMap *corev1.ConfigMap) (ProcessConfigMapResult, error) {
	logger := log.FromContext(ctx)
	result := ProcessConfigMapResult{}
	var processedRoleBindings []string
	var validWhitelistEntries []string // For LDAP group creation

	// Look for whitelist.txt key in ConfigMap
	whitelistContent, found := configMap.Data["whitelist.txt"]
	if !found {
		logger.Info("No whitelist.txt found in ConfigMap, skipping processing")
		return result, nil
	}

	// Parse whitelist.txt line by line
	lines := strings.Split(whitelistContent, "\n")
	for lineNum, line := range lines {
		line = strings.TrimSpace(line)

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Extract CN value from LDAP DN format
		// Example: CN=DD_0000-K8S-123-Cluster-admin,OU=Openshift-123,...
		cnValue, err := r.extractCNFromDN(line)
		if err != nil {
			configMapEntriesProcessed.WithLabelValues("error").Inc()
			logger.Error(err, "Failed to extract CN from LDAP DN", "line", lineNum+1, "content", line)
			continue
		}

		// Check if the CN value is in the exclude list
		if r.isExcluded(cnValue, permissionBinder.Spec.ExcludeList) {
			configMapEntriesProcessed.WithLabelValues("excluded").Inc()
			logger.Info("Skipping excluded CN", "cn", cnValue)
			continue
		}

		// Parse the CN value to extract namespace and role (try all prefixes)
		namespace, role, matchedPrefix, err := r.parsePermissionStringWithPrefixes(cnValue, permissionBinder.Spec.Prefixes, permissionBinder.Spec.RoleMapping)
		if err != nil {
			configMapEntriesProcessed.WithLabelValues("error").Inc()
			logger.Error(err, "Failed to parse permission string", "cn", cnValue, "line", lineNum+1)
			continue
		}

		logger.V(1).Info("Parsed permission string", "cn", cnValue, "prefix", matchedPrefix, "namespace", namespace, "role", role)

		// Add to valid entries for LDAP processing (use original line with full DN)
		validWhitelistEntries = append(validWhitelistEntries, line)

		// Ensure namespace exists
		if err := r.ensureNamespace(ctx, namespace, permissionBinder); err != nil {
			logger.Error(err, "Failed to ensure namespace exists", "namespace", namespace)
			continue
		}

		// Create RoleBinding (use the CN value as the group subject name)
		// OpenShift LDAP syncer creates groups with CN value as name, not full DN
		roleBindingName := fmt.Sprintf("%s-%s", namespace, role)
		if err := r.createRoleBinding(ctx, namespace, roleBindingName, role, cnValue, permissionBinder.Spec.RoleMapping[role], permissionBinder); err != nil {
			logger.Error(err, "Failed to create RoleBinding", "namespace", namespace, "role", role)
			continue
		}

		processedRoleBindings = append(processedRoleBindings, fmt.Sprintf("%s/%s", namespace, roleBindingName))
		configMapEntriesProcessed.WithLabelValues("success").Inc()
		logger.Info("Created RoleBinding", "namespace", namespace, "role", role, "groupName", cnValue)
	}

	// Process LDAP group creation if enabled
	if permissionBinder.Spec.CreateLdapGroups && len(validWhitelistEntries) > 0 {
		logger.Info("🔐 LDAP group creation is enabled, processing entries", "count", len(validWhitelistEntries))
		if err := r.ProcessLdapGroupCreation(ctx, permissionBinder, validWhitelistEntries); err != nil {
			// Log error but don't fail the entire reconciliation
			logger.Error(err, "⚠️  LDAP group creation failed (non-fatal)", "validEntries", len(validWhitelistEntries))
		}
	}

	// Process ServiceAccount creation if configured
	// ServiceAccounts are created per namespace based on serviceAccountMapping
	// This happens for each namespace that was processed above
	var allProcessedSAs []string
	if len(permissionBinder.Spec.ServiceAccountMapping) > 0 {
		// Get unique namespaces from processed RoleBindings
		namespaces := make(map[string]bool)
		for _, rb := range processedRoleBindings {
			// RoleBinding format: "namespace/rolebinding-name"
			parts := strings.Split(rb, "/")
			if len(parts) == 2 {
				namespaces[parts[0]] = true
			}
		}

		logger.Info("🔑 ServiceAccount mapping configured, creating ServiceAccounts",
			"mappings", len(permissionBinder.Spec.ServiceAccountMapping),
			"namespaces", len(namespaces))

		// Process each namespace
		for namespace := range namespaces {
			processedSAs, err := ProcessServiceAccounts(
				ctx,
				r.Client,
				namespace,
				permissionBinder.Spec.ServiceAccountMapping,
				permissionBinder.Spec.ServiceAccountNamingPattern,
				permissionBinder.Name,
			)
			if err != nil {
				// Log error but don't fail the entire reconciliation
				logger.Error(err, "⚠️  ServiceAccount creation failed (non-fatal)",
					"namespace", namespace)
			} else {
				allProcessedSAs = append(allProcessedSAs, processedSAs...)
				logger.Info("✅ ServiceAccounts processed successfully",
					"namespace", namespace,
					"created", len(processedSAs))
			}
		}

		// Update managedServiceAccountsTotal metric
		managedServiceAccountsTotal.Set(float64(len(allProcessedSAs)))
	}

	// Populate result
	result.ProcessedRoleBindings = processedRoleBindings
	result.ProcessedServiceAccounts = allProcessedSAs

	return result, nil
}

// extractCNFromDN extracts the CN (Common Name) value from an LDAP DN string
// Example: "CN=DD_0000-K8S-123-admin,OU=..." -> "DD_0000-K8S-123-admin"
func (r *PermissionBinderReconciler) extractCNFromDN(dn string) (string, error) {
	// Find CN= prefix
	cnPrefix := "CN="
	cnIndex := strings.Index(dn, cnPrefix)
	if cnIndex == -1 {
		return "", fmt.Errorf("CN not found in DN: %s", dn)
	}

	// Extract everything after CN=
	afterCN := dn[cnIndex+len(cnPrefix):]

	// Find the end of CN value (marked by comma)
	commaIndex := strings.Index(afterCN, ",")
	if commaIndex == -1 {
		// No comma found, use the entire remaining string
		return strings.TrimSpace(afterCN), nil
	}

	// Extract CN value up to the comma
	cnValue := strings.TrimSpace(afterCN[:commaIndex])
	return cnValue, nil
}

// isExcluded checks if a key is in the exclude list
func (r *PermissionBinderReconciler) isExcluded(key string, excludeList []string) bool {
	for _, excluded := range excludeList {
		if key == excluded {
			return true
		}
	}
	return false
}

// parsePermissionStringWithPrefixes tries to parse permission string with multiple prefixes
// Returns namespace, role, matched prefix, and error
func (r *PermissionBinderReconciler) parsePermissionStringWithPrefixes(permissionString string, prefixes []string, roleMapping map[string]string) (string, string, string, error) {
	// Try each prefix (longest first to handle overlapping prefixes like "MT-K8S-DEV" and "MT-K8S")
	sortedPrefixes := make([]string, len(prefixes))
	copy(sortedPrefixes, prefixes)

	// Sort by length descending (longest first)
	for i := 0; i < len(sortedPrefixes); i++ {
		for j := i + 1; j < len(sortedPrefixes); j++ {
			if len(sortedPrefixes[j]) > len(sortedPrefixes[i]) {
				sortedPrefixes[i], sortedPrefixes[j] = sortedPrefixes[j], sortedPrefixes[i]
			}
		}
	}

	for _, prefix := range sortedPrefixes {
		namespace, role, err := r.parsePermissionString(permissionString, prefix, roleMapping)
		if err == nil {
			return namespace, role, prefix, nil
		}
	}

	return "", "", "", fmt.Errorf("no matching prefix found for: %s (available prefixes: %v)", permissionString, prefixes)
}

// parsePermissionString parses a permission string like "COMPANY-K8S-project-123-engineer"
// and returns namespace and role. The role is determined by checking against roleMapping keys,
// which allows namespaces to contain hyphens (e.g., "project-123").
// If multiple roles match, the longest role name is used (e.g., "read-only" before "only").
func (r *PermissionBinderReconciler) parsePermissionString(permissionString, prefix string, roleMapping map[string]string) (string, string, error) {
	// Remove prefix
	withoutPrefix := strings.TrimPrefix(permissionString, prefix+"-")
	if withoutPrefix == permissionString {
		return "", "", fmt.Errorf("permission string does not start with prefix: %s", prefix)
	}

	// Try to match known roles from roleMapping by checking suffixes
	// This allows namespaces to contain hyphens (e.g., "project-123-engineer" where role="engineer" and namespace="project-123")
	// If multiple roles match, prefer the longest one (e.g., "read-only" over "only")
	var matchedRole string
	var namespace string
	var maxRoleLength int

	for role := range roleMapping {
		// Check if the string ends with "-{role}"
		suffix := "-" + role
		if strings.HasSuffix(withoutPrefix, suffix) {
			// Found a matching role - prefer longer role names
			if len(role) > maxRoleLength {
				matchedRole = role
				namespace = strings.TrimSuffix(withoutPrefix, suffix)
				maxRoleLength = len(role)
			}
		}
	}

	if matchedRole == "" {
		return "", "", fmt.Errorf("no matching role found in roleMapping for: %s (available roles: %v)", permissionString, getMapKeys(roleMapping))
	}

	if namespace == "" {
		return "", "", fmt.Errorf("invalid permission string format: namespace cannot be empty in %s", permissionString)
	}

	return namespace, matchedRole, nil
}

// getMapKeys returns the keys of a map as a slice (helper for error messages)
func getMapKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	return keys
}

// ensureNamespace creates a namespace if it doesn't exist
func (r *PermissionBinderReconciler) ensureNamespace(ctx context.Context, namespace string, permissionBinder *permissionv1.PermissionBinder) error {
	logger := log.FromContext(ctx)
	var ns corev1.Namespace
	err := r.Get(ctx, types.NamespacedName{Name: namespace}, &ns)
	if err != nil {
		if errors.IsNotFound(err) {
			// Create namespace with annotations
			now := time.Now().Format(time.RFC3339)
			ns = corev1.Namespace{
				ObjectMeta: metav1.ObjectMeta{
					Name: namespace,
					Annotations: map[string]string{
						AnnotationManagedBy:        ManagedByValue,
						AnnotationCreatedAt:        now,
						AnnotationPermissionBinder: permissionBinder.Name,
					},
					Labels: map[string]string{
						LabelManagedBy: ManagedByValue,
					},
				},
			}
			if err := r.Create(ctx, &ns); err != nil {
				return fmt.Errorf("failed to create namespace %s: %w", namespace, err)
			}
		} else {
			return fmt.Errorf("failed to get namespace %s: %w", namespace, err)
		}
	} else {
		// Update existing namespace with annotations if not present
		needsUpdate := false
		if ns.Annotations == nil {
			ns.Annotations = make(map[string]string)
		}
		if ns.Labels == nil {
			ns.Labels = make(map[string]string)
		}

		// ADOPTION LOGIC: Remove orphaned annotations if present
		// This allows automatic recovery when PermissionBinder is recreated
		if ns.Annotations["permission-binder.io/orphaned-at"] != "" {
			delete(ns.Annotations, "permission-binder.io/orphaned-at")
			delete(ns.Annotations, "permission-binder.io/orphaned-by")
			needsUpdate = true

			// Increment adoption metrics (automatic recovery)
			adoptionEventsTotal.Inc()

			logger.Info("Adopted orphaned namespace - removed orphaned annotations",
				"namespace", namespace,
				"permissionBinder", permissionBinder.Name,
				"action", "adoption",
				"recovery", "automatic")
		}

		if ns.Annotations[AnnotationManagedBy] != ManagedByValue {
			ns.Annotations[AnnotationManagedBy] = ManagedByValue
			needsUpdate = true
		}
		if ns.Annotations[AnnotationPermissionBinder] != permissionBinder.Name {
			ns.Annotations[AnnotationPermissionBinder] = permissionBinder.Name
			needsUpdate = true
		}
		if ns.Annotations[AnnotationCreatedAt] == "" {
			ns.Annotations[AnnotationCreatedAt] = time.Now().Format(time.RFC3339)
			needsUpdate = true
		}
		if ns.Labels[LabelManagedBy] != ManagedByValue {
			ns.Labels[LabelManagedBy] = ManagedByValue
			needsUpdate = true
		}

		if needsUpdate {
			if err := r.Update(ctx, &ns); err != nil {
				return fmt.Errorf("failed to update namespace %s: %w", namespace, err)
			}
		}
	}
	return nil
}

// validateClusterRoleExists checks if the ClusterRole exists and logs a warning if it doesn't
// This is important for production environments to ensure proper RBAC configuration
func (r *PermissionBinderReconciler) validateClusterRoleExists(ctx context.Context, clusterRoleName string) bool {
	logger := log.FromContext(ctx)

	var clusterRole rbacv1.ClusterRole
	if err := r.Get(ctx, types.NamespacedName{Name: clusterRoleName}, &clusterRole); err != nil {
		if errors.IsNotFound(err) {
			// Increment metrics for missing ClusterRole (security critical!)
			missingClusterRoleTotal.WithLabelValues(clusterRoleName, "unknown").Inc()

			logger.Info("ClusterRole does not exist - RoleBinding will be created but will not grant permissions until ClusterRole is created",
				"clusterRole", clusterRoleName,
				"severity", "warning",
				"action_required", "create_clusterrole",
				"impact", "no_permissions_granted")
			return false
		}
		// Other errors (e.g., permission denied) - log but continue
		logger.Error(err, "Failed to check ClusterRole existence",
			"clusterRole", clusterRoleName,
			"severity", "error")
		return false
	}
	return true
}

// createRoleBinding creates a RoleBinding in the specified namespace
func (r *PermissionBinderReconciler) createRoleBinding(ctx context.Context, namespace, name, _, group, clusterRole string, permissionBinder *permissionv1.PermissionBinder) error {
	logger := log.FromContext(ctx)
	now := time.Now().Format(time.RFC3339)

	// Validate ClusterRole exists before creating RoleBinding
	// This is a critical security check for production environments
	clusterRoleExists := r.validateClusterRoleExists(ctx, clusterRole)
	if !clusterRoleExists {
		logger.Info("Creating RoleBinding with non-existent ClusterRole",
			"namespace", namespace,
			"roleBinding", name,
			"clusterRole", clusterRole,
			"group", group,
			"severity", "warning",
			"security_impact", "high")
	}

	roleBinding := &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
			Annotations: map[string]string{
				AnnotationManagedBy:        ManagedByValue,
				AnnotationCreatedAt:        now,
				AnnotationPermissionBinder: permissionBinder.Name,
			},
			Labels: map[string]string{
				LabelManagedBy: ManagedByValue,
			},
		},
		Subjects: []rbacv1.Subject{
			{
				Kind: "Group",
				Name: group,
			},
		},
		RoleRef: rbacv1.RoleRef{
			Kind:     "ClusterRole",
			Name:     clusterRole,
			APIGroup: "rbac.authorization.k8s.io",
		},
	}

	// Check if RoleBinding already exists
	var existing rbacv1.RoleBinding
	err := r.Get(ctx, types.NamespacedName{Name: name, Namespace: namespace}, &existing)
	if err != nil {
		if errors.IsNotFound(err) {
			// Create new RoleBinding
			if err := r.Create(ctx, roleBinding); err != nil {
				return fmt.Errorf("failed to create RoleBinding %s/%s: %w", namespace, name, err)
			}
		} else {
			return fmt.Errorf("failed to get RoleBinding %s/%s: %w", namespace, name, err)
		}
	} else {
		// Update existing RoleBinding - OVERRIDE any manual changes
		// This ensures consistency and predictability in production environments
		existing.Subjects = roleBinding.Subjects
		existing.RoleRef = roleBinding.RoleRef

		// Update annotations and labels
		if existing.Annotations == nil {
			existing.Annotations = make(map[string]string)
		}
		if existing.Labels == nil {
			existing.Labels = make(map[string]string)
		}

		// ADOPTION LOGIC: Remove orphaned annotations if present
		// This allows automatic recovery when PermissionBinder is recreated
		if existing.Annotations["permission-binder.io/orphaned-at"] != "" {
			delete(existing.Annotations, "permission-binder.io/orphaned-at")
			delete(existing.Annotations, "permission-binder.io/orphaned-by")

			// Increment adoption metrics (automatic recovery)
			adoptionEventsTotal.Inc()

			logger.Info("Adopted orphaned RoleBinding - removed orphaned annotations",
				"namespace", namespace,
				"roleBinding", name,
				"permissionBinder", permissionBinder.Name,
				"action", "adoption",
				"recovery", "automatic")
		}

		existing.Annotations[AnnotationManagedBy] = ManagedByValue
		existing.Annotations[AnnotationPermissionBinder] = permissionBinder.Name
		if existing.Annotations[AnnotationCreatedAt] == "" {
			existing.Annotations[AnnotationCreatedAt] = now
		}
		existing.Labels[LabelManagedBy] = ManagedByValue

		if err := r.Update(ctx, &existing); err != nil {
			return fmt.Errorf("failed to update RoleBinding %s/%s: %w", namespace, name, err)
		}
	}

	return nil
}

// hasRoleMappingChanged checks if the role mapping has changed
func (r *PermissionBinderReconciler) hasRoleMappingChanged(_ *permissionv1.PermissionBinder) bool {
	// For now, we'll always return true to trigger reconciliation
	// In a production environment, you might want to store the previous state
	// and compare it with the current state
	return true
}

// reconcileAllManagedResources reconciles all managed resources when role mapping changes
func (r *PermissionBinderReconciler) reconcileAllManagedResources(ctx context.Context, permissionBinder *permissionv1.PermissionBinder) error {
	logger := log.FromContext(ctx)

	// Get all managed namespaces
	managedNamespaces, err := r.getManagedNamespaces(ctx, permissionBinder)
	if err != nil {
		return fmt.Errorf("failed to get managed namespaces: %w", err)
	}

	// Get all managed role bindings
	managedRoleBindings, err := r.getManagedRoleBindings(ctx, permissionBinder)
	if err != nil {
		return fmt.Errorf("failed to get managed role bindings: %w", err)
	}

	// Check each namespace for missing role bindings
	for _, namespace := range managedNamespaces {
		for role := range permissionBinder.Spec.RoleMapping {
			roleBindingName := fmt.Sprintf("%s-%s", namespace, role)

			// Check if role binding exists
			var existing rbacv1.RoleBinding
			err := r.Get(ctx, types.NamespacedName{Name: roleBindingName, Namespace: namespace}, &existing)
			if err != nil {
				if errors.IsNotFound(err) {
					// Role binding doesn't exist, create it
					// It will be recreated on next reconciliation from ConfigMap data
					logger.Info("RoleBinding missing - will be recreated on next reconciliation",
						"namespace", namespace, "role", role)
				} else {
					logger.Error(err, "Failed to check RoleBinding", "namespace", namespace, "role", role)
				}
			}
		}
	}

	// Remove role bindings for roles that no longer exist in mapping
	for _, roleBinding := range managedRoleBindings {
		role := r.extractRoleFromRoleBindingName(roleBinding.Name)
		if role != "" && !r.roleExistsInMapping(role, permissionBinder.Spec.RoleMapping) {
			if err := r.Delete(ctx, &roleBinding); err != nil {
				logger.Error(err, "Failed to delete obsolete RoleBinding", "namespace", roleBinding.Namespace, "name", roleBinding.Name)
			} else {
				logger.Info("Deleted obsolete RoleBinding", "namespace", roleBinding.Namespace, "name", roleBinding.Name)
			}
		}
	}

	// Remove role bindings that don't match any current prefix
	for _, roleBinding := range managedRoleBindings {
		if len(roleBinding.Subjects) > 0 {
			groupName := roleBinding.Subjects[0].Name
			matchesAnyPrefix := false
			for _, prefix := range permissionBinder.Spec.Prefixes {
				if strings.HasPrefix(groupName, prefix+"-") {
					matchesAnyPrefix = true
					break
				}
			}
			if !matchesAnyPrefix {
				if err := r.Delete(ctx, &roleBinding); err != nil {
					logger.Error(err, "Failed to delete RoleBinding with invalid prefix", "namespace", roleBinding.Namespace, "name", roleBinding.Name, "group", groupName)
				} else {
					logger.Info("Deleted RoleBinding with invalid prefix", "namespace", roleBinding.Namespace, "name", roleBinding.Name, "group", groupName)
				}
			}
		}
	}

	return nil
}

// cleanupManagedResources cleans up all resources managed by this PermissionBinder
// SAFE MODE: We do NOT delete RoleBindings or namespaces when PermissionBinder is deleted
// This prevents cascade failures and accidental data loss
func (r *PermissionBinderReconciler) cleanupManagedResources(ctx context.Context, permissionBinder *permissionv1.PermissionBinder) error {
	logger := log.FromContext(ctx)

	logger.Info("PermissionBinder is being deleted - SAFE MODE: RoleBindings and namespaces will be preserved to prevent cascade failures")

	// Get all managed role bindings to add cleanup annotation
	roleBindings, err := r.getManagedRoleBindings(ctx, permissionBinder)
	if err != nil {
		logger.Error(err, "Failed to get managed role bindings for annotation")
	} else {
		for _, roleBinding := range roleBindings {
			// Add annotation indicating PermissionBinder was deleted but RoleBinding is preserved
			if roleBinding.Annotations == nil {
				roleBinding.Annotations = make(map[string]string)
			}
			roleBinding.Annotations["permission-binder.io/orphaned-at"] = time.Now().Format(time.RFC3339)
			roleBinding.Annotations["permission-binder.io/orphaned-by"] = "permission-binder-deletion"

			if err := r.Update(ctx, &roleBinding); err != nil {
				logger.Error(err, "Failed to annotate RoleBinding as orphaned", "namespace", roleBinding.Namespace, "name", roleBinding.Name)
			} else {
				logger.Info("Annotated RoleBinding as orphaned", "namespace", roleBinding.Namespace, "name", roleBinding.Name)
			}
		}
	}

	// Get all managed namespaces to add cleanup annotation
	namespaces, err := r.getManagedNamespaces(ctx, permissionBinder)
	if err != nil {
		logger.Error(err, "Failed to get managed namespaces for annotation")
	} else {
		for _, namespace := range namespaces {
			var ns corev1.Namespace
			if err := r.Get(ctx, types.NamespacedName{Name: namespace}, &ns); err != nil {
				logger.Error(err, "Failed to get namespace for annotation", "namespace", namespace)
				continue
			}

			// Add annotation indicating PermissionBinder was deleted but namespace is preserved
			if ns.Annotations == nil {
				ns.Annotations = make(map[string]string)
			}
			ns.Annotations["permission-binder.io/orphaned-at"] = time.Now().Format(time.RFC3339)
			ns.Annotations["permission-binder.io/orphaned-by"] = "permission-binder-deletion"

			if err := r.Update(ctx, &ns); err != nil {
				logger.Error(err, "Failed to annotate namespace as orphaned", "namespace", namespace)
			} else {
				logger.Info("Annotated namespace as orphaned", "namespace", namespace)
			}
		}
	}

	logger.Info("SAFE MODE cleanup completed - all managed resources preserved with orphaned annotations")
	return nil
}

// getManagedNamespaces returns all namespaces managed by this PermissionBinder
func (r *PermissionBinderReconciler) getManagedNamespaces(ctx context.Context, permissionBinder *permissionv1.PermissionBinder) ([]string, error) {
	var namespaces corev1.NamespaceList

	// Create label selector for managed namespaces
	selector := labels.NewSelector()
	req, err := labels.NewRequirement(LabelManagedBy, selection.Equals, []string{ManagedByValue})
	if err != nil {
		return nil, err
	}
	selector = selector.Add(*req)

	if err := r.List(ctx, &namespaces, &client.ListOptions{LabelSelector: selector}); err != nil {
		return nil, err
	}

	var result []string
	for _, ns := range namespaces.Items {
		// Filter by permission binder annotation
		if ns.Annotations != nil && ns.Annotations[AnnotationPermissionBinder] == permissionBinder.Name {
			result = append(result, ns.Name)
		}
	}

	return result, nil
}

// getManagedRoleBindings returns all role bindings managed by this PermissionBinder
func (r *PermissionBinderReconciler) getManagedRoleBindings(ctx context.Context, permissionBinder *permissionv1.PermissionBinder) ([]rbacv1.RoleBinding, error) {
	var roleBindings rbacv1.RoleBindingList

	// Create label selector for managed role bindings
	selector := labels.NewSelector()
	req, err := labels.NewRequirement(LabelManagedBy, selection.Equals, []string{ManagedByValue})
	if err != nil {
		return nil, err
	}
	selector = selector.Add(*req)

	if err := r.List(ctx, &roleBindings, &client.ListOptions{LabelSelector: selector}); err != nil {
		return nil, err
	}

	// Filter by permission binder annotation
	var result []rbacv1.RoleBinding
	for _, rb := range roleBindings.Items {
		if rb.Annotations != nil && rb.Annotations[AnnotationPermissionBinder] == permissionBinder.Name {
			result = append(result, rb)
		}
	}

	return result, nil
}

// Helper function to check if a slice contains a string
func containsString(slice []string, s string) bool {
	for _, item := range slice {
		if item == s {
			return true
		}
	}
	return false
}

// Helper function to remove a string from a slice
func removeString(slice []string, s string) []string {
	var result []string
	for _, item := range slice {
		if item != s {
			result = append(result, item)
		}
	}
	return result
}

// extractRoleFromRoleBindingName extracts the role from a role binding name
func (r *PermissionBinderReconciler) extractRoleFromRoleBindingName(name string) string {
	parts := strings.Split(name, "-")
	if len(parts) >= 2 {
		return parts[len(parts)-1]
	}
	return ""
}

// roleExistsInMapping checks if a role exists in the role mapping
func (r *PermissionBinderReconciler) roleExistsInMapping(role string, mapping map[string]string) bool {
	_, exists := mapping[role]
	return exists
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

// mapConfigMapToPermissionBinder maps ConfigMap changes to PermissionBinder reconciliation
// This ensures operator reacts to ConfigMap changes automatically
func (r *PermissionBinderReconciler) mapConfigMapToPermissionBinder(ctx context.Context, obj *corev1.ConfigMap) []reconcile.Request {

	// Get all PermissionBinders that might be using this ConfigMap
	var permissionBinders permissionv1.PermissionBinderList
	if err := r.List(ctx, &permissionBinders); err != nil {
		return []reconcile.Request{}
	}

	var requests []reconcile.Request
	for _, pb := range permissionBinders.Items {
		// Check if this ConfigMap is referenced by this PermissionBinder
		if pb.Spec.ConfigMapName == obj.Name && pb.Spec.ConfigMapNamespace == obj.Namespace {
			requests = append(requests, reconcile.Request{
				NamespacedName: types.NamespacedName{
					Name:      pb.Name,
					Namespace: pb.Namespace,
				},
			})
		}
	}

	return requests
}

// SetupWithManager sets up the controller with the Manager.
func (r *PermissionBinderReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&permissionv1.PermissionBinder{}).
		Watches(
			&corev1.ConfigMap{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				configMap, ok := obj.(*corev1.ConfigMap)
				if !ok {
					return []reconcile.Request{}
				}
				return r.mapConfigMapToPermissionBinder(ctx, configMap)
			}),
			builder.WithPredicates(predicate.ResourceVersionChangedPredicate{}),
		).
		Complete(r)
}
