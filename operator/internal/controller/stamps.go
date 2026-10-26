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
	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
	"github.com/permission-binder-operator/operator/internal/metadata"
)

// The per-kind stamps. Each constructor is the one place that decides what a
// resource of that kind carries, and internal/metadata.Apply is the one place
// that writes it - the four kinds used to be stamped by seven hand-rolled
// if-chains that had drifted apart (the ServiceAccount flow wrote a
// differently named created-by, no created-at, and never re-stamped ownership
// on adoption).
//
// ManagedByValue is read here rather than inside the metadata package so that
// package holds no mutable global and the MANAGED_BY_VALUE override stays
// testable.

// namespaceStamp is the stamp for a namespace the operator creates or adopts.
func namespaceStamp(permissionBinder *permissionv1.PermissionBinder) metadata.Stamp {
	return metadata.Stamp{
		ManagedBy:      ManagedByValue,
		Owner:          permissionBinder.Name,
		OwnerNamespace: permissionBinder.Namespace,
	}
}

// groupRoleBindingStamp is the stamp for a RoleBinding that binds an LDAP
// group. The role key is stamped so a role name containing hyphens survives
// round-tripping through the RoleBinding name.
func groupRoleBindingStamp(permissionBinder *permissionv1.PermissionBinder, role string) metadata.Stamp {
	return metadata.Stamp{
		ManagedBy:      ManagedByValue,
		Owner:          permissionBinder.Name,
		OwnerNamespace: permissionBinder.Namespace,
		Role:           role,
	}
}

// serviceAccountStamp is the stamp for a managed ServiceAccount. The
// ServiceAccount flow carries the owner identity as plain strings, so it does
// not take the CR.
func serviceAccountStamp(ownerName, ownerNamespace, saType, roleName string) metadata.Stamp {
	return metadata.Stamp{
		ManagedBy:       ManagedByValue,
		Owner:           ownerName,
		OwnerNamespace:  ownerNamespace,
		Role:            roleName,
		SAType:          saType,
		AppComponent:    saType,
		AppName:         ownerName,
		LegacyCreatedBy: true,
	}
}

// serviceAccountRoleBindingStamp is the stamp for the RoleBinding that binds a
// managed ServiceAccount. It records the ServiceAccount instead of a role: the
// role comes from spec.serviceAccountMapping and is already on the SA itself.
func serviceAccountRoleBindingStamp(ownerName, ownerNamespace, saType, serviceAccount string) metadata.Stamp {
	return metadata.Stamp{
		ManagedBy:       ManagedByValue,
		Owner:           ownerName,
		OwnerNamespace:  ownerNamespace,
		SAType:          saType,
		ServiceAccount:  serviceAccount,
		AppComponent:    "service-account-binding",
		AppName:         ownerName,
		LegacyCreatedBy: true,
	}
}
