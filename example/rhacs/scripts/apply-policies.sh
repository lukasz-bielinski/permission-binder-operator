#!/bin/bash
set -e

# Script to apply RHACS policies via roxctl CLI
# Requires: roxctl CLI tool and RHACS admin credentials

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║         Apply RHACS Policies                                            ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Check prerequisites
if ! command -v roxctl &> /dev/null; then
    echo "❌ roxctl CLI not found."
    echo "Run: ./apply-cosign-integration.sh (it will install roxctl)"
    exit 1
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
    exit 1
fi

echo "✅ RHACS Central: https://${RHACS_ROUTE}"

# Get API token
if [ -z "$ROX_API_TOKEN" ]; then
    echo ""
    echo "⚠️  ROX_API_TOKEN environment variable not set."
    echo -n "Enter API Token: "
    read -s ROX_API_TOKEN
    echo ""
fi

export ROX_ENDPOINT="${RHACS_ROUTE}:443"

# Test connection
echo ""
echo "🔍 Testing connection..."
if ! roxctl --endpoint "${ROX_ENDPOINT}" --token-file <(echo -n "${ROX_API_TOKEN}") central whoami &>/dev/null; then
    echo "❌ Failed to connect to RHACS."
    exit 1
fi

echo "✅ Connected to RHACS"

# Apply policies
echo ""
echo "📝 Applying policies..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="${SCRIPT_DIR}/../policies"

if [ ! -d "$POLICIES_DIR" ]; then
    echo "❌ Policies directory not found: $POLICIES_DIR"
    exit 1
fi

POLICY_COUNT=0
SUCCESS_COUNT=0
FAIL_COUNT=0

for policy_file in "${POLICIES_DIR}"/*.json; do
    if [ -f "$policy_file" ]; then
        POLICY_COUNT=$((POLICY_COUNT + 1))
        policy_name=$(basename "$policy_file")
        
        echo ""
        echo "📄 Applying: $policy_name"
        
        if roxctl --endpoint "${ROX_ENDPOINT}" \
           --token-file <(echo -n "${ROX_API_TOKEN}") \
           central policy import \
           --file "$policy_file" &>/dev/null; then
            echo "   ✅ Success"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "   ⚠️  Failed or already exists"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
done

# Summary
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║  Summary                                                                ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo "Total policies: ${POLICY_COUNT}"
echo "Successfully applied: ${SUCCESS_COUNT}"
echo "Failed/Existing: ${FAIL_COUNT}"
echo ""

if [ $SUCCESS_COUNT -gt 0 ]; then
    echo "✅ Policies applied successfully!"
    echo ""
    echo "Verify in RHACS UI:"
    echo "  https://${RHACS_ROUTE} → Platform Configuration → Policy Management"
    echo ""
    echo "Test deployment:"
    echo "  oc apply -k ../../"
    echo ""
else
    echo "⚠️  No new policies were applied (might already exist)."
    echo "Check RHACS UI: https://${RHACS_ROUTE}"
fi

