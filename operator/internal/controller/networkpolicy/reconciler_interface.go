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

// Package networkpolicy provides GitOps-based NetworkPolicy management for Kubernetes.
//
// This package implements a GitOps workflow for managing NetworkPolicies:
//   - Templates are stored in a Git repository
//   - NetworkPolicies are generated from templates for each namespace
//   - Changes are committed to Git and submitted as Pull Requests
//   - Supports multiple Git providers (GitHub, GitLab, Bitbucket)
//   - Includes drift detection and periodic reconciliation
//
// The package is designed to work with the PermissionBinder operator and uses
// the ReconcilerInterface to interact with the Kubernetes API.
package networkpolicy

import (
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// ReconcilerInterface defines the interface needed by NetworkPolicy functions.
// It embeds client.Reader, client.Writer, and client.StatusClient to provide
// a minimal interface for Kubernetes API operations.
//
// This interface allows NetworkPolicy functions to work with any reconciler
// that implements these methods, enabling better testability and separation
// of concerns.
type ReconcilerInterface interface {
	client.Reader
	client.Writer
	client.StatusClient
}
