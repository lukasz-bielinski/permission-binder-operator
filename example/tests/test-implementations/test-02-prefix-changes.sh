#!/bin/bash
# Test 02: Prefix Changes
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 2: Prefix Changes"
echo "-----------------------"

# A prefix-only spec change must be applied on its own (issue #94): the
# reconciler's skip guard includes the spec generation, so the prefix patch
# below is followed by NO ConfigMap edit and NO annotation poke. The entry
# under the new prefix is seeded and proven consumed BEFORE the patch, which
# leaves the generation bump as the only change the operator can act on.

# Test namespace carries the per-instance prefix (empty in legacy mode)
TEST2_NS="${TEST_NS_PREFIX}test-02-prefix"
WHITELIST_PREFIX="${RUN_DIR:-/tmp}/whitelist-prefix.txt"
PB_NAME="permissionbinder-example"
NEW_RB="$TEST2_NS $TEST2_NS-admin"

# rb_list_inline <"namespace name" lines> - the list as one comma-separated line
rb_list_inline() {
    printf '%s' "$1" | tr '\n' ',' | sed 's/,/, /g'
}

# pb_field <jsonpath> - one field of the CR under test; empty on a transient
# API error so the polls below simply retry.
pb_field() {
    kubectl get permissionbinder "$PB_NAME" -n "$NAMESPACE" -o jsonpath="$1" 2>/dev/null
}

# configmap_consumed <previous_rv> - the whitelist ConfigMap moved past
# <previous_rv> AND status.lastProcessedConfigMapVersion equals its LIVE
# resourceVersion (both reads must succeed). Requiring a NEW version keeps a
# failed apply from being read as "already consumed".
configmap_consumed() {
    local cm_rv
    cm_rv=$(kubectl get configmap permission-config -n "$NAMESPACE" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)
    [ -n "$cm_rv" ] && [ "$cm_rv" != "$1" ] && [ "$(pb_field '{.status.lastProcessedConfigMapVersion}')" = "$cm_rv" ]
}

# configmap_rv - live resourceVersion of the whitelist ConfigMap (empty on error)
configmap_rv() {
    kubectl get configmap permission-config -n "$NAMESPACE" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null
}

# spec_processed <generation> - the Processed condition AND
# status.lastProcessedGeneration both observe the given generation
spec_processed() {
    kubectl get permissionbinder "$PB_NAME" -n "$NAMESPACE" -o json 2>/dev/null | jq -e --argjson g "$1" '
        (.status.conditions // [] | any(.type == "Processed" and .observedGeneration == $g))
        and ((.status.lastProcessedGeneration // 0) == $g)' >/dev/null
}

# owned_rolebindings_snapshot - list_owned_rolebindings, but a failed API call
# fails the snapshot: an empty list must never read as "all gone". pipefail
# inside the substitution surfaces the kubectl status behind the helper's jq.
owned_rolebindings_snapshot() {
    local out
    out=$(set -o pipefail; list_owned_rolebindings "$PB_NAME") || return 1
    printf '%s\n' "$out"
}

# have_owned_rolebindings - at least one RoleBinding is owned right now
have_owned_rolebindings() {
    [ -n "$(owned_rolebindings_snapshot)" ]
}

# all_rolebindings_absent <"namespace name" lines> - none is owned right now
all_rolebindings_absent() {
    local current line
    current=$(owned_rolebindings_snapshot) || return 1
    while read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "$current" | grep -qxF "$line" && return 1
    done <<< "$1"
    return 0
}

# all_rolebindings_present <"namespace name" lines> - every one is owned right now
all_rolebindings_present() {
    local current line
    current=$(owned_rolebindings_snapshot) || return 1
    while read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "$current" | grep -qxF "$line" || return 1
    done <<< "$1"
    return 0
}

# ----------------------------------------------------------------------------
# Phase 0: baseline - the RoleBindings owned under the current prefix. Every
# one of them must disappear on the prefix change and come back on restore.
# ----------------------------------------------------------------------------
# The runner declares the baseline reconciled as soon as the fixture namespace
# exists; its RoleBinding is the next API call of the same pass, so poll.
if ! wait_for_cmd 30 have_owned_rolebindings; then
    fail_test "Baseline fixture contract broken: no RoleBindings owned by $PB_NAME within $(e2e_max_wait 30)s before the prefix change"
    exit 1
fi
OLD_RBS=$(owned_rolebindings_snapshot)
info_log "Baseline RoleBindings under COMPANY-K8S: $(rb_list_inline "$OLD_RBS")"

# ----------------------------------------------------------------------------
# Phase 1: seed the new-prefix entry BEFORE the prefix change. Under
# COMPANY-K8S it is inert (rejected: no matching prefix), and waiting until
# the CR has consumed this exact ConfigMap version proves the edit is fully
# processed before the prefix patch - so nothing but the patch is in flight.
# ----------------------------------------------------------------------------
NEW_ENTRY="CN=NEW-PREFIX-${TEST2_NS}-admin,OU=TestOU,DC=example,DC=com"
# Plain kubectl here: kubectl_retry folds stderr into stdout, and an error
# message must never be written back as the whitelist.
CURRENT_WHITELIST=$(kubectl get configmap permission-config -n "$NAMESPACE" -o jsonpath='{.data.whitelist\.txt}' 2>/dev/null) || {
    fail_test "Cannot read the whitelist ConfigMap before seeding the new-prefix entry"
    exit 1
}
printf '%s\n%s\n' "$CURRENT_WHITELIST" "$NEW_ENTRY" > "$WHITELIST_PREFIX"
CM_RV_BEFORE_SEED=$(configmap_rv)
kubectl create configmap permission-config -n "$NAMESPACE" --from-file=whitelist.txt="$WHITELIST_PREFIX" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || {
    fail_test "Failed to apply the seeded whitelist ConfigMap"
    rm -f "$WHITELIST_PREFIX"
    exit 1
}
rm -f "$WHITELIST_PREFIX"

if ! wait_for_cmd 60 configmap_consumed "$CM_RV_BEFORE_SEED"; then
    fail_test "Seeded ConfigMap edit not consumed: status.lastProcessedConfigMapVersion did not reach the ConfigMap resourceVersion within $(e2e_max_wait 60)s"
    exit 1
fi
CM_VERSION_SEEDED=$(pb_field '{.status.lastProcessedConfigMapVersion}')
info_log "Seeded new-prefix entry consumed (lastProcessedConfigMapVersion $CM_VERSION_SEEDED)"

# kubectl_retry folds stderr into stdout, so "NotFound" would count as a line:
# test the exit status, not the line count (test 03 pattern).
if kubectl_retry kubectl get namespace "$TEST2_NS" >/dev/null 2>&1; then
    fail_test "Namespace $TEST2_NS exists before the prefix change (NEW-PREFIX entry must be inert under COMPANY-K8S)"
else
    pass_test "New-prefix entry inert under the old prefix (namespace $TEST2_NS not created)"
fi

# ----------------------------------------------------------------------------
# Phase 2: prefix-only spec change - the fix under test (issue #94). Only the
# generation moves; the ConfigMap stays exactly as consumed in phase 1.
# ----------------------------------------------------------------------------
GEN_BEFORE=$(pb_field '{.metadata.generation}')
kubectl_retry kubectl patch permissionbinder "$PB_NAME" -n "$NAMESPACE" --type=json \
  -p='[{"op":"replace","path":"/spec/prefixes","value":["NEW-PREFIX"]}]' >/dev/null 2>&1
GEN_AFTER=$(pb_field '{.metadata.generation}')
info_log "Prefix patched COMPANY-K8S -> NEW-PREFIX (generation $GEN_BEFORE -> $GEN_AFTER)"
if [ -z "$GEN_AFTER" ] || [ "$GEN_AFTER" = "$GEN_BEFORE" ]; then
    fail_test "Prefix patch did not bump metadata.generation (before=$GEN_BEFORE, after=$GEN_AFTER)"
    exit 1
fi

if wait_for_cmd 60 spec_processed "$GEN_AFTER"; then
    pass_test "Prefix-only spec change processed (Processed.observedGeneration and lastProcessedGeneration = $GEN_AFTER, no ConfigMap edit)"
else
    fail_test "Prefix-only spec change was not processed: Processed.observedGeneration / status.lastProcessedGeneration did not reach generation $GEN_AFTER within $(e2e_max_wait 60)s (issue #94 regression)"
fi

# (a) every old-prefix RoleBinding is removed (managed-resource cleanup:
#     the group matches none of the new prefixes)
if wait_for_cmd 30 all_rolebindings_absent "$OLD_RBS"; then
    pass_test "Old-prefix RoleBindings removed after the prefix change"
else
    fail_test "Old-prefix RoleBindings still owned after the prefix change (expected gone: $(rb_list_inline "$OLD_RBS"))"
fi

# (b) the seeded new-prefix entry now yields its namespace + RoleBinding
if kubectl_retry kubectl get namespace "$TEST2_NS" >/dev/null 2>&1; then
    pass_test "Namespace created for entry with new prefix"
else
    fail_test "Namespace $TEST2_NS not created for new-prefix entry"
fi
if wait_for_cmd 30 all_rolebindings_present "$NEW_RB"; then
    pass_test "RoleBinding created for entry with new prefix"
else
    fail_test "RoleBinding $TEST2_NS/$TEST2_NS-admin not created for new-prefix entry"
fi

# (c) the old-prefix entries were re-evaluated under the new prefix set:
#     "no matching prefix found ... (available prefixes: [NEW-PREFIX])"
if kubectl logs -n "$NAMESPACE" deployment/operator-controller-manager --tail=300 2>/dev/null \
    | grep -qF "available prefixes: [NEW-PREFIX]"; then
    pass_test "Operator rejected old-prefix entries under the new prefix set"
else
    fail_test "Operator logs do not show old-prefix entries rejected under NEW-PREFIX (no 'available prefixes: [NEW-PREFIX]' in the last 300 lines)"
fi

# (d) no ConfigMap change was involved: the consumed version is the phase 1 one
CM_VERSION_AFTER_PATCH=$(pb_field '{.status.lastProcessedConfigMapVersion}')
if [ -n "$CM_VERSION_AFTER_PATCH" ] && [ "$CM_VERSION_AFTER_PATCH" = "$CM_VERSION_SEEDED" ]; then
    pass_test "status.lastProcessedConfigMapVersion unchanged across the prefix-only patch ($CM_VERSION_SEEDED)"
else
    fail_test "status.lastProcessedConfigMapVersion changed across the prefix-only patch ($CM_VERSION_SEEDED -> $CM_VERSION_AFTER_PATCH)"
fi

# ----------------------------------------------------------------------------
# Phase 3: restore the original prefix and drop the new-prefix entry again so
# the restore does not re-remove it on every subsequent reconcile. The way
# back is the same mechanism in reverse: the NEW-PREFIX RoleBinding must go,
# the baseline ones must come back.
# ----------------------------------------------------------------------------
kubectl_retry kubectl patch permissionbinder "$PB_NAME" -n "$NAMESPACE" --type=json \
  -p='[{"op":"replace","path":"/spec/prefixes","value":["COMPANY-K8S"]}]' >/dev/null 2>&1
GEN_RESTORED=$(pb_field '{.metadata.generation}')
if [ -z "$GEN_RESTORED" ] || [ "$GEN_RESTORED" = "$GEN_AFTER" ]; then
    fail_test "Prefix restore patch did not bump metadata.generation (before=$GEN_AFTER, after=$GEN_RESTORED)"
fi
CURRENT_WHITELIST=$(kubectl get configmap permission-config -n "$NAMESPACE" -o jsonpath='{.data.whitelist\.txt}' 2>/dev/null) || {
    fail_test "Cannot read the whitelist ConfigMap before removing the new-prefix entry"
    exit 1
}
printf '%s\n' "$CURRENT_WHITELIST" | grep -v "NEW-PREFIX" > "$WHITELIST_PREFIX" || true
kubectl create configmap permission-config -n "$NAMESPACE" --from-file=whitelist.txt="$WHITELIST_PREFIX" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || {
    fail_test "Failed to apply the trimmed whitelist ConfigMap"
    rm -f "$WHITELIST_PREFIX"
    exit 1
}
rm -f "$WHITELIST_PREFIX"

# The ConfigMap was last consumed at CM_VERSION_SEEDED (prefix patches do not
# touch it), so the trimmed version must be a newer one.
restore_reconciled() {
    spec_processed "$GEN_RESTORED" && configmap_consumed "$CM_VERSION_SEEDED"
}
if [ -n "$GEN_RESTORED" ] && wait_for_cmd 60 restore_reconciled; then
    pass_test "Prefix restore processed (generation $GEN_RESTORED and the trimmed ConfigMap both consumed)"
else
    fail_test "Prefix restore not processed: generation $GEN_RESTORED / trimmed ConfigMap not consumed within $(e2e_max_wait 60)s"
fi

if wait_for_cmd 30 all_rolebindings_present "$OLD_RBS"; then
    pass_test "Original-prefix RoleBindings restored"
else
    fail_test "Original-prefix RoleBindings not restored (expected back: $(rb_list_inline "$OLD_RBS"))"
fi
if wait_for_cmd 30 all_rolebindings_absent "$NEW_RB"; then
    pass_test "New-prefix RoleBinding removed on the way back (prefix cleanup)"
else
    fail_test "RoleBinding $TEST2_NS/$TEST2_NS-admin still owned after restoring COMPANY-K8S"
fi

echo ""

# ============================================================================
