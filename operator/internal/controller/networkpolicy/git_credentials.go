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
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

// getGitCredentials retrieves Git credentials from Secret.
// Returns credentials with default username/email if not specified in Secret.
func getGitCredentials(r ReconcilerInterface, ctx context.Context, secretRef *permissionv1.LdapSecretReference) (*gitCredentials, error) {
	var secret corev1.Secret
	if err := r.Get(ctx, types.NamespacedName{
		Name:      secretRef.Name,
		Namespace: secretRef.Namespace,
	}, &secret); err != nil {
		return nil, fmt.Errorf("failed to get Git credentials Secret: %w", err)
	}

	token, ok := secret.Data["token"]
	if !ok {
		return nil, fmt.Errorf("token not found in Secret %s/%s", secretRef.Namespace, secretRef.Name)
	}

	username := string(secret.Data["username"])
	if username == "" {
		username = "permission-binder-operator"
	}

	email := string(secret.Data["email"])
	if email == "" {
		email = "permission-binder-operator@example.com"
	}

	return &gitCredentials{
		token:    string(token),
		username: username,
		email:    email,
	}, nil
}

