#!/bin/bash
set -e

# Script to verify RHACS setup and image signature verification

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║         RHACS Setup Verification                                        ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Check OpenShift CLI
if ! command -v oc &> /dev/null; then
    echo "❌ oc CLI not found"
    exit 1
fi

# Check Cosign CLI (optional but recommended)
if command -v cosign &> /dev/null; then
    echo "✅ cosign CLI found"
    COSIGN_AVAILABLE=true
else
    echo "⚠️  cosign CLI not found (optional)"
    COSIGN_AVAILABLE=false
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "1. Checking RHACS Operator Installation"
echo "════════════════════════════════════════════════════════════════════════════"

if oc get subscription rhacs-operator -n rhacs-operator &>/dev/null; then
    echo "✅ RHACS Operator subscription exists"
    
    CSV=$(oc get subscription rhacs-operator -n rhacs-operator -o jsonpath='{.status.currentCSV}')
    if [ -n "$CSV" ]; then
        echo "   📦 Current CSV: $CSV"
        
        CSV_PHASE=$(oc get csv "$CSV" -n rhacs-operator -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo "   📊 Phase: $CSV_PHASE"
        
        if [ "$CSV_PHASE" == "Succeeded" ]; then
            echo "   ✅ Operator is ready"
        else
            echo "   ⚠️  Operator phase is not 'Succeeded'"
        fi
    fi
else
    echo "❌ RHACS Operator subscription not found"
    echo "   Run: oc apply -f 03-subscription.yaml"
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "2. Checking RHACS Central"
echo "════════════════════════════════════════════════════════════════════════════"

if oc get central rhacs-operator-central-services -n rhacs-operator &>/dev/null; then
    echo "✅ Central resource exists"
    
    CENTRAL_STATUS=$(oc get central rhacs-operator-central-services -n rhacs-operator -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status}' 2>/dev/null || echo "Unknown")
    echo "   📊 Deployed status: $CENTRAL_STATUS"
    
    if oc get deployment central -n rhacs-operator &>/dev/null; then
        CENTRAL_READY=$(oc get deployment central -n rhacs-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        CENTRAL_DESIRED=$(oc get deployment central -n rhacs-operator -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        echo "   📊 Ready replicas: ${CENTRAL_READY}/${CENTRAL_DESIRED}"
        
        if [ "$CENTRAL_READY" == "$CENTRAL_DESIRED" ] && [ "$CENTRAL_READY" != "0" ]; then
            echo "   ✅ Central is ready"
            
            # Get route
            RHACS_ROUTE=$(oc get route central -n rhacs-operator -o jsonpath='{.spec.host}' 2>/dev/null)
            if [ -n "$RHACS_ROUTE" ]; then
                echo "   🌐 URL: https://${RHACS_ROUTE}"
                
                # Get admin password
                RHACS_PASSWORD=$(oc get secret central-htpasswd -n rhacs-operator -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
                if [ -n "$RHACS_PASSWORD" ]; then
                    echo "   🔑 Admin password: ${RHACS_PASSWORD}"
                fi
            fi
        else
            echo "   ⚠️  Central is not fully ready"
        fi
    fi
else
    echo "❌ Central resource not found"
    echo "   Run: oc apply -f 04-central.yaml"
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "3. Checking SecuredCluster (Admission Controller)"
echo "════════════════════════════════════════════════════════════════════════════"

if oc get securedcluster rhacs-operator-secured-cluster-services -n rhacs-operator &>/dev/null; then
    echo "✅ SecuredCluster resource exists"
    
    if oc get deployment sensor -n rhacs-operator &>/dev/null; then
        SENSOR_READY=$(oc get deployment sensor -n rhacs-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        echo "   📊 Sensor ready replicas: ${SENSOR_READY}"
    fi
    
    if oc get deployment admission-control -n rhacs-operator &>/dev/null; then
        AC_READY=$(oc get deployment admission-control -n rhacs-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        AC_DESIRED=$(oc get deployment admission-control -n rhacs-operator -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        echo "   📊 Admission Control ready replicas: ${AC_READY}/${AC_DESIRED}"
        
        if [ "$AC_READY" == "$AC_DESIRED" ] && [ "$AC_READY" != "0" ]; then
            echo "   ✅ Admission Control is ready"
        else
            echo "   ⚠️  Admission Control is not fully ready"
        fi
    fi
    
    # Check ValidatingWebhookConfiguration
    if oc get validatingwebhookconfigurations | grep -q rhacs-operator; then
        echo "   ✅ Admission webhook is registered"
    else
        echo "   ⚠️  Admission webhook not found"
    fi
else
    echo "❌ SecuredCluster resource not found"
    echo "   Run: oc apply -f 05-secured-cluster.yaml"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "4. Checking Scanner"
echo "════════════════════════════════════════════════════════════════════════════"

if oc get deployment scanner -n rhacs-operator &>/dev/null; then
    SCANNER_READY=$(oc get deployment scanner -n rhacs-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    echo "   📊 Scanner ready replicas: ${SCANNER_READY}"
    
    if [ "$SCANNER_READY" != "0" ]; then
        echo "   ✅ Scanner is ready"
    else
        echo "   ⚠️  Scanner is not ready"
    fi
else
    echo "   ℹ️  Scanner not deployed (optional)"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "5. Testing Image Signature Verification"
echo "════════════════════════════════════════════════════════════════════════════"

if [ "$COSIGN_AVAILABLE" = true ]; then
    echo "Testing Cosign signature for permission-binder-operator:1.8.1..."
    
    if cosign verify \
        --certificate-identity-regexp "https://github.com/lukasz-bielinski/permission-binder-operator" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
        docker.io/lukaszbielinski/permission-binder-operator:1.8.1 &>/dev/null; then
        echo "✅ Image signature verification PASSED"
    else
        echo "❌ Image signature verification FAILED"
    fi
else
    echo "⚠️  Skipping signature test (cosign not installed)"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "6. Next Steps"
echo "════════════════════════════════════════════════════════════════════════════"

if [ -n "$RHACS_ROUTE" ]; then
    echo ""
    echo "🎯 Configure Cosign Integration:"
    echo "   1. Login to: https://${RHACS_ROUTE}"
    echo "   2. Go to: Platform Configuration → Integrations → Signature Integrations"
    echo "   3. Create Cosign integration (see cosign-integration-config.yaml)"
    echo "   Or run: ./apply-cosign-integration.sh"
    echo ""
    echo "📝 Apply Policies:"
    echo "   Run: ./apply-policies.sh"
    echo ""
    echo "🧪 Test Deployment:"
    echo "   Run: oc apply -k ../../"
    echo "   (Should succeed if signature verification is configured correctly)"
    echo ""
fi

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║  Verification Complete                                                  ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"

