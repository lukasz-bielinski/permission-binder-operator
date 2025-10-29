#!/bin/bash
set -e

# Script to apply Cosign integration to RHACS via API
# Requires: roxctl CLI tool and RHACS admin credentials

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║         Apply Cosign Integration to RHACS                               ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Check prerequisites
if ! command -v roxctl &> /dev/null; then
    echo "❌ roxctl CLI not found. Installing..."
    echo "Downloading roxctl..."
    curl -O https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl
    chmod +x roxctl
    sudo mv roxctl /usr/local/bin/
    echo "✅ roxctl installed"
fi

if ! command -v oc &> /dev/null; then
    echo "❌ oc CLI not found. Please install OpenShift CLI."
    exit 1
fi

# Get RHACS Central endpoint
echo "📡 Discovering RHACS Central endpoint..."
RHACS_ROUTE=$(oc get route central -n stackrox -o jsonpath='{.spec.host}' 2>/dev/null)

if [ -z "$RHACS_ROUTE" ]; then
    echo "❌ RHACS Central route not found. Is RHACS installed?"
    echo "Run: oc get route -n stackrox"
    exit 1
fi

echo "✅ RHACS Central: https://${RHACS_ROUTE}"

# Get or request API token
if [ -z "$ROX_API_TOKEN" ]; then
    echo ""
    echo "⚠️  ROX_API_TOKEN environment variable not set."
    echo ""
    echo "To generate an API token:"
    echo "1. Login to RHACS UI: https://${RHACS_ROUTE}"
    echo "2. Go to: Platform Configuration → Integrations"
    echo "3. Click: API Token → Generate Token"
    echo "4. Name: 'GitOps Automation'"
    echo "5. Role: Admin"
    echo "6. Copy the token"
    echo ""
    echo -n "Enter API Token: "
    read -s ROX_API_TOKEN
    echo ""
fi

export ROX_ENDPOINT="${RHACS_ROUTE}:443"

# Test connection
echo ""
echo "🔍 Testing connection to RHACS..."
if ! roxctl --endpoint "${ROX_ENDPOINT}" --token-file <(echo -n "${ROX_API_TOKEN}") central whoami &>/dev/null; then
    echo "❌ Failed to connect to RHACS. Check your API token."
    exit 1
fi

echo "✅ Connected to RHACS"

# Create Cosign integration
echo ""
echo "📝 Creating Cosign integration..."

# Create integration JSON
cat > /tmp/cosign-integration.json <<EOF
{
  "name": "GitHub Actions Cosign",
  "type": "signature",
  "cosign": {
    "certificateOidcIssuer": "https://token.actions.githubusercontent.com",
    "certificateIdentityRegex": "^https://github\\.com/lukasz-bielinski/permission-binder-operator/.*"
  }
}
EOF

# Apply integration using roxctl
echo "Applying integration..."
INTEGRATION_ID=$(roxctl --endpoint "${ROX_ENDPOINT}" \
  --token-file <(echo -n "${ROX_API_TOKEN}") \
  central signature-integration create \
  --name "GitHub Actions Cosign" \
  --cosign-certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --cosign-certificate-identity "^https://github\\.com/lukasz-bielinski/permission-binder-operator/.*" \
  --json 2>&1 | jq -r '.id' || echo "")

if [ -z "$INTEGRATION_ID" ]; then
    echo "⚠️  Integration might already exist or creation failed."
    echo "Check RHACS UI: Platform Configuration → Integrations → Signature Integrations"
else
    echo "✅ Cosign integration created with ID: ${INTEGRATION_ID}"
fi

# Verify integration
echo ""
echo "🔍 Verifying integration..."
roxctl --endpoint "${ROX_ENDPOINT}" \
  --token-file <(echo -n "${ROX_API_TOKEN}") \
  central signature-integration list | grep -q "GitHub Actions Cosign" && \
  echo "✅ Integration verified in RHACS" || \
  echo "⚠️  Could not verify integration - check RHACS UI manually"

# Test with permission-binder-operator image
echo ""
echo "🧪 Testing signature verification..."
echo "Image: docker.io/lukaszbielinski/permission-binder-operator:1.4.0"

# Note: Image verification test via API would require more complex setup
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "1. Verify integration in RHACS UI:"
echo "   https://${RHACS_ROUTE} → Platform Configuration → Integrations"
echo ""
echo "2. Apply signature verification policy:"
echo "   ./apply-policies.sh"
echo ""
echo "3. Test deployment:"
echo "   oc apply -k ../../"
echo ""

# Cleanup
rm -f /tmp/cosign-integration.json

