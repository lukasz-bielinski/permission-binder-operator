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
	"crypto/tls"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/go-ldap/ldap/v3"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// LdapGroupInfo contains parsed information about LDAP group from CN
type LdapGroupInfo struct {
	GroupName string // e.g., "MT-K8S-tenant1-project1-engineer"
	Path      string // e.g., "OU=Tenant1,OU=Kubernetes,DC=example,DC=com"
	FullDN    string // Full Distinguished Name
}

// LdapCredentials contains LDAP connection credentials from Secret
type LdapCredentials struct {
	Server   string
	Username string
	Password string
}

// ParseCN extracts group name and path from LDAP CN string
// Input: "CN=MT-K8S-tenant1-project1-engineer,OU=Tenant1,OU=Kubernetes,DC=example,DC=com"
// Output: GroupName="MT-K8S-tenant1-project1-engineer", Path="OU=Tenant1,OU=Kubernetes,DC=example,DC=com"
func ParseCN(cn string) (*LdapGroupInfo, error) {
	// Regex to extract CN and the rest of the path
	re := regexp.MustCompile(`^CN=([^,]+),(.+)$`)
	matches := re.FindStringSubmatch(cn)

	if len(matches) != 3 {
		return nil, fmt.Errorf("invalid CN format: %s (expected: CN=groupname,OU=...,DC=...)", cn)
	}

	return &LdapGroupInfo{
		GroupName: matches[1],
		Path:      matches[2],
		FullDN:    cn,
	}, nil
}

// GetLdapCredentials retrieves LDAP credentials from Secret referenced in PermissionBinder
func (r *PermissionBinderReconciler) GetLdapCredentials(ctx context.Context, pb *permissionv1.PermissionBinder) (*LdapCredentials, error) {
	logger := log.FromContext(ctx)

	if pb.Spec.LdapSecretRef == nil {
		return nil, fmt.Errorf("ldapSecretRef is not configured")
	}

	// Fetch the Secret
	secret := &corev1.Secret{}
	secretKey := client.ObjectKey{
		Name:      pb.Spec.LdapSecretRef.Name,
		Namespace: pb.Spec.LdapSecretRef.Namespace,
	}

	if err := r.Get(ctx, secretKey, secret); err != nil {
		logger.Error(err, "Failed to get LDAP credentials Secret",
			"secret", secretKey.Name,
			"namespace", secretKey.Namespace)
		return nil, err
	}

	// Extract required fields
	server, ok := secret.Data["domain_server"]
	if !ok {
		return nil, fmt.Errorf("domain_server not found in Secret %s/%s", secret.Namespace, secret.Name)
	}

	username, ok := secret.Data["domain_username"]
	if !ok {
		return nil, fmt.Errorf("domain_username not found in Secret %s/%s", secret.Namespace, secret.Name)
	}

	password, ok := secret.Data["domain_password"]
	if !ok {
		return nil, fmt.Errorf("domain_password not found in Secret %s/%s", secret.Namespace, secret.Name)
	}

	logger.Info("Successfully retrieved LDAP credentials",
		"secret", secretKey.Name,
		"namespace", secretKey.Namespace,
		"server", string(server))

	return &LdapCredentials{
		Server:   string(server),
		Username: string(username),
		Password: string(password),
	}, nil
}

// ConnectLdap establishes connection to LDAP/AD server
func ConnectLdap(creds *LdapCredentials) (*ldap.Conn, error) {
	var conn *ldap.Conn
	var err error

	// Check if using LDAPS (secure)
	if strings.HasPrefix(creds.Server, "ldaps://") {
		// LDAPS connection
		serverAddr := strings.TrimPrefix(creds.Server, "ldaps://")
		conn, err = ldap.DialURL(fmt.Sprintf("ldaps://%s", serverAddr), ldap.DialWithTLSConfig(&tls.Config{
			InsecureSkipVerify: false, // TODO: Make this configurable via CRD
		}))
	} else {
		// Plain LDAP connection
		serverAddr := strings.TrimPrefix(creds.Server, "ldap://")
		if !strings.Contains(serverAddr, "://") {
			serverAddr = creds.Server // No prefix, assume plain
		}
		conn, err = ldap.DialURL(fmt.Sprintf("ldap://%s", serverAddr))
	}

	if err != nil {
		ldapConnectionsTotal.WithLabelValues("error").Inc()
		return nil, fmt.Errorf("failed to connect to LDAP server %s: %w", creds.Server, err)
	}

	// Bind (authenticate)
	err = conn.Bind(creds.Username, creds.Password)
	if err != nil {
		conn.Close()
		ldapConnectionsTotal.WithLabelValues("error").Inc()
		return nil, fmt.Errorf("failed to bind to LDAP server: %w", err)
	}

	ldapConnectionsTotal.WithLabelValues("success").Inc()
	return conn, nil
}

// CreateLdapGroup creates an LDAP/AD group if it doesn't exist
func CreateLdapGroup(ctx context.Context, conn *ldap.Conn, groupInfo *LdapGroupInfo, clusterName string) error {
	logger := log.FromContext(ctx)

	// Check if group already exists
	searchRequest := ldap.NewSearchRequest(
		groupInfo.FullDN,
		ldap.ScopeBaseObject,
		ldap.NeverDerefAliases,
		0, 0, false,
		"(objectClass=*)",
		[]string{"cn", "description"},
		nil,
	)

	sr, err := conn.Search(searchRequest)
	if err == nil && len(sr.Entries) > 0 {
		logger.Info("ℹ️  AD Group already exists (skipping creation)",
			"group", groupInfo.GroupName,
			"dn", groupInfo.FullDN,
			"cluster", clusterName)
		ldapGroupOperationsTotal.WithLabelValues("exists").Inc()
		return nil // Group exists, nothing to do
	}

	// Group doesn't exist, create it with cluster information
	timestamp := time.Now().UTC().Format("2006-01-02 15:04:05 UTC")
	description := fmt.Sprintf("Created by permission-binder-operator from cluster '%s' on %s. Kubernetes namespace permission group.", clusterName, timestamp)

	addRequest := ldap.NewAddRequest(groupInfo.FullDN, nil)
	addRequest.Attribute("objectClass", []string{"top", "group"})
	addRequest.Attribute("cn", []string{groupInfo.GroupName})
	addRequest.Attribute("sAMAccountName", []string{groupInfo.GroupName})
	addRequest.Attribute("description", []string{description})

	err = conn.Add(addRequest)
	if err != nil {
		// Check if error is "already exists" (race condition)
		if ldap.IsErrorWithCode(err, ldap.LDAPResultEntryAlreadyExists) {
			logger.Info("ℹ️  AD Group already exists (race condition - created by another operator instance)",
				"group", groupInfo.GroupName,
				"dn", groupInfo.FullDN,
				"cluster", clusterName)
			ldapGroupOperationsTotal.WithLabelValues("exists").Inc()
			return nil
		}
		ldapGroupOperationsTotal.WithLabelValues("error").Inc()
		return fmt.Errorf("failed to create LDAP group %s: %w", groupInfo.FullDN, err)
	}

	ldapGroupOperationsTotal.WithLabelValues("created").Inc()
	logger.Info("✅ Successfully created AD Group",
		"group", groupInfo.GroupName,
		"dn", groupInfo.FullDN,
		"path", groupInfo.Path,
		"cluster", clusterName,
		"description", description)

	return nil
}

// GetClusterName attempts to detect the cluster name from Kubernetes API server
func (r *PermissionBinderReconciler) GetClusterName(ctx context.Context) string {
	// Try to get cluster name from kube-system ConfigMap (common pattern)
	configMap := &corev1.ConfigMap{}
	err := r.Get(ctx, client.ObjectKey{Name: "cluster-info", Namespace: "kube-system"}, configMap)
	if err == nil {
		if clusterName, ok := configMap.Data["cluster-name"]; ok && clusterName != "" {
			return clusterName
		}
	}

	// Fallback: try to get from kube-public namespace
	err = r.Get(ctx, client.ObjectKey{Name: "cluster-info", Namespace: "kube-public"}, configMap)
	if err == nil {
		if clusterName, ok := configMap.Data["cluster-name"]; ok && clusterName != "" {
			return clusterName
		}
	}

	// Fallback: use hostname or default
	// In production, cluster name should be configured via ConfigMap or env var
	return "kubernetes-cluster"
}

// ProcessLdapGroupCreation handles LDAP group creation for all whitelist entries
func (r *PermissionBinderReconciler) ProcessLdapGroupCreation(ctx context.Context, pb *permissionv1.PermissionBinder, whitelistEntries []string) error {
	logger := log.FromContext(ctx)

	if !pb.Spec.CreateLdapGroups {
		logger.V(1).Info("LDAP group creation disabled, skipping")
		return nil
	}

	logger.Info("🔐 Starting LDAP group creation process",
		"entries", len(whitelistEntries))

	// Get cluster name for AD group description
	clusterName := r.GetClusterName(ctx)
	logger.Info("Detected cluster name", "cluster", clusterName)

	// Get LDAP credentials
	creds, err := r.GetLdapCredentials(ctx, pb)
	if err != nil {
		logger.Error(err, "Failed to get LDAP credentials")
		return err
	}

	// Connect to LDAP
	conn, err := ConnectLdap(creds)
	if err != nil {
		logger.Error(err, "Failed to connect to LDAP server")
		return err
	}
	defer conn.Close()

	logger.Info("Connected to LDAP server", "server", creds.Server)

	// Process each whitelist entry
	successCount := 0
	errorCount := 0

	for _, entry := range whitelistEntries {
		// Parse CN to extract group info
		groupInfo, err := ParseCN(entry)
		if err != nil {
			logger.Error(err, "Failed to parse CN", "entry", entry)
			errorCount++
			continue
		}

		// Create LDAP group (with cluster name in description)
		err = CreateLdapGroup(ctx, conn, groupInfo, clusterName)
		if err != nil {
			logger.Error(err, "Failed to create LDAP group",
				"group", groupInfo.GroupName,
				"dn", groupInfo.FullDN)
			errorCount++
			continue
		}

		successCount++
	}

	logger.Info("✅ LDAP group creation completed",
		"created", successCount,
		"errors", errorCount,
		"total", len(whitelistEntries),
		"cluster", clusterName)

	// Return error only if ALL operations failed
	if errorCount > 0 && successCount == 0 {
		return fmt.Errorf("all LDAP group creation operations failed (%d errors)", errorCount)
	}

	return nil
}
