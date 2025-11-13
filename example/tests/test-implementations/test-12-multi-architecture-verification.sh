#!/bin/bash
# Test 12: Multi Architecture Verification
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 12: Multi-Architecture Verification"
echo "-----------------------------------------"

# Check available node architectures
AVAILABLE_ARCHS=$(kubectl_retry kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}' | tr ' ' '\n' | sort -u | xargs)
info_log "Available node architectures: $AVAILABLE_ARCHS"

# Count distinct architectures
ARCH_COUNT=$(echo "$AVAILABLE_ARCHS" | wc -w)

if [ "$ARCH_COUNT" -lt 2 ]; then
    info_log "Single architecture cluster detected - skipping multi-arch verification"
    pass_test "Multi-arch test skipped (single architecture cluster)"
else
    info_log "Multi-architecture cluster detected - testing cross-arch deployment"
    
    # Save original replica count
    ORIGINAL_REPLICAS=$(kubectl_retry kubectl get deployment operator-controller-manager -n $NAMESPACE -o jsonpath='{.spec.replicas}')
    info_log "Original replicas: $ORIGINAL_REPLICAS"
    
    # Patch deployment with 2 replicas + pod anti-affinity on architecture
    kubectl_retry kubectl patch deployment operator-controller-manager -n $NAMESPACE --type=json -p='[
        {"op":"replace","path":"/spec/replicas","value":2},
        {"op":"add","path":"/spec/template/spec/affinity","value":{
            "podAntiAffinity":{
                "requiredDuringSchedulingIgnoredDuringExecution":[{
                    "labelSelector":{
                        "matchExpressions":[{
                            "key":"control-plane",
                            "operator":"In",
                            "values":["controller-manager"]
                        }]
                    },
                    "topologyKey":"kubernetes.io/arch"
                }]
            }
        }}
    ]' >/dev/null 2>&1
    
    # Wait for 2 pods to be ready
    info_log "Waiting for 2 replicas to be ready..."
    kubectl_retry kubectl wait --for=condition=available --timeout=60s deployment/operator-controller-manager -n $NAMESPACE >/dev/null 2>&1
    sleep 5
    
    # Check if we got pods on different architectures
    POD_ARCHS=$(kubectl_retry kubectl get pods -n $NAMESPACE -l control-plane=controller-manager -o json | \
        jq -r '.items[] | .spec.nodeName as $node | ($node + ":" + (.metadata.name | split("-")[-1]))' | \
        while read pod_info; do
            node=$(echo $pod_info | cut -d: -f1)
            arch=$(kubectl_retry kubectl get node $node -o jsonpath='{.status.nodeInfo.architecture}' 2>/dev/null)
            echo "$arch"
        done | sort -u)
    
    RUNNING_ARCH_COUNT=$(echo "$POD_ARCHS" | grep -v "^$" | wc -l)
    
    if [ "$RUNNING_ARCH_COUNT" -eq 2 ]; then
        pass_test "Operator successfully running on multiple architectures: $(echo $POD_ARCHS | xargs)"
        info_log "✅ Multi-arch deployment verified"
    else
        fail_test "Operator not running on multiple architectures (found: $RUNNING_ARCH_COUNT)"
    fi
    
    # Restore original replica count and remove affinity
    info_log "Restoring original deployment configuration..."
    kubectl_retry kubectl patch deployment operator-controller-manager -n $NAMESPACE --type=json -p='[
        {"op":"replace","path":"/spec/replicas","value":'$ORIGINAL_REPLICAS'},
        {"op":"remove","path":"/spec/template/spec/affinity"}
    ]' >/dev/null 2>&1
    
    # Wait for stabilization
    kubectl_retry kubectl wait --for=condition=available --timeout=30s deployment/operator-controller-manager -n $NAMESPACE >/dev/null 2>&1
    sleep 3
    info_log "Deployment restored to $ORIGINAL_REPLICAS replica(s)"
fi

echo ""

# ============================================================================
