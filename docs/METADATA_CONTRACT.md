# Managed-resource metadata contract

Every resource the operator creates, adopts or orphans carries one stamp: a
fixed set of `permission-binder.io/*` annotations plus the
`permission-binder.io/managed-by` label. The contract is owned by one package,
[`operator/internal/metadata`](../operator/internal/metadata/stamp.go), and
written by one function (`metadata.Apply`); the per-kind variations live in the
four stamp constructors in
[`operator/internal/controller/stamps.go`](../operator/internal/controller/stamps.go).

## The stamp

| Key | Kind | Meaning |
|---|---|---|
| `permission-binder.io/managed-by` (annotation **and** label) | all | The operator instance (`MANAGED_BY_VALUE`). The **label** is the only way the operator finds its own resources cluster-wide, so every managed resource carries it. |
| `permission-binder.io/created-at` | all | First stamp, RFC3339 UTC. Write-once: on a resource adopted later it marks the adoption, not the resource's own creation. |
| `permission-binder.io/permission-binder` | all | Name of the owning PermissionBinder CR. |
| `permission-binder.io/permission-binder-namespace` | all | Namespace of the owning CR. Together with the name it makes ownership unique per operator instance. |
| `permission-binder.io/role` | group RoleBinding, ServiceAccount | Full role key from `spec.roleMapping` / `spec.serviceAccountMapping`, so a role name with hyphens survives round-tripping through the resource name. |
| `permission-binder.io/sa-type` | ServiceAccount, SA RoleBinding | The `spec.serviceAccountMapping` key (`deploy`, `runtime`, …). |
| `permission-binder.io/service-account` | SA RoleBinding | The ServiceAccount the RoleBinding binds. |
| `permission-binder.io/created-by` | ServiceAccount, SA RoleBinding | **Deprecated** spelling of `managed-by`, same value. Written because every ServiceAccount in the field carries it; read `managed-by`. |
| `permission-binder.io/orphaned-at`, `…/orphaned-by` | all | Set by SAFE-MODE cleanup when the CR is deleted (resources are preserved, not deleted). Their presence makes a resource adoptable by another CR; adoption removes them and counts `permission_binder_adoption_events_total`. |
| `app.kubernetes.io/managed-by`, `…/component`, `…/name` (labels) | ServiceAccount, SA RoleBinding | The recommended Kubernetes labels, where a component/name pair is meaningful. |

Keys the operator does not own are never touched: a user's own annotations and
labels survive every pass.

## Per-kind matrix

| | Namespace | Group RoleBinding | ServiceAccount | SA RoleBinding |
|---|---|---|---|---|
| `managed-by` (annotation) | ✅ | ✅ | ✅ | ✅ |
| `managed-by` (label) | ✅ | ✅ | ✅ | ✅ |
| `created-at` | ✅ | ✅ | ✅ | ✅ |
| `permission-binder`, `…-namespace` | ✅ | ✅ | ✅ | ✅ |
| `role` | — | ✅ | ✅ | — (role lives on the SA) |
| `sa-type` | — | — | ✅ | ✅ |
| `service-account` | — | — | — | ✅ |
| `created-by` (deprecated) | — | — | ✅ | ✅ |
| `app.kubernetes.io/*` | — | — | ✅ | ✅ |
| orphan markers on CR deletion | ✅ | ✅ | ✅ | ✅ |

## When the stamp is written

- **Create** — the stamp is part of the object sent to the API server.
- **Adopt** — anything found to exist already, whether by the initial `Get` or
  by the re-read after a `Create` lost an `AlreadyExists` race, is re-stamped
  in place. A metadata-only change is a plain `Update`: never delete+recreate,
  which would briefly drop granted permissions.
- **Every pass** — `metadata.Apply` reconciles drift and reports whether it
  changed anything, so an up-to-date resource costs no `Update` (no
  ResourceVersion churn, no watch traffic).
- **Ownership gate** — adoption always runs behind `canTakeOwnership`: a
  resource with a live claim by *another* PermissionBinder is never written to
  (issue #43). Unclaimed, own, legacy name-only and explicitly orphaned
  resources are adoptable.
- **After an operator upgrade** — the skip guard only sees ConfigMap,
  roleMapping and spec changes, none of which happen when the operator itself
  changes, so the first pass per CR after a process start is forced. Resources
  no longer in scope (a namespace dropped from the whitelist, an SA removed
  from the mapping) are not revisited and keep whatever stamp they had.

## What is deliberately outside the contract

- **`permission-binder.io/finalizer`** on the PermissionBinder CR: a lifecycle
  hook on the operator's own CR, not a managed-resource marker.
- **NetworkPolicy GitOps** writes `network-policy.permission-binder.io/template`,
  `…/template-path` and `…/template-version` on manifests it renders into a Git
  repository. Those are not live objects the operator owns, they carry no
  ownership annotations, and drift detection recognises its own policies by
  `…/template` alone. The feature ships disabled (`ENABLE_NETWORK_POLICY`).

## History: the divergence this replaced

The contract used to be seven hand-rolled if-chains across two flows, and they
had drifted:

| Divergence | Consequence |
|---|---|
| The SA flow wrote `created-by`; the group flow wrote `managed-by` | Two names for one fact; no query matched both halves. |
| The SA flow stamped no `managed-by` **label** | `-l permission-binder.io/managed-by` returned an incomplete inventory, and SAFE-MODE cleanup could not orphan-annotate ServiceAccounts or their RoleBindings. |
| The SA flow had no `created-at` | No stamp age on half the fleet. |
| ServiceAccount ownership annotations were never re-stamped on adoption | A legacy SA stayed unclaimed indefinitely. |
| A `Create` that lost an `AlreadyExists` race skipped the stamp entirely (SA flow) | A managed object could stay unstamped until something else happened to touch it. |

All five are closed; `created-by` is kept as a deprecated alias.
