#!/bin/bash
# Test 18: Json Structured Logging Verification Audit
# Source common functions
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$SCRIPT_DIR/test-common.sh"

# ============================================================================
# ============================================================================
echo "Test 18: JSON Structured Logging Verification (Audit)"
echo "-------------------------------------------------------"

# Extract operator logs
ALL_LOGS=$(kubectl logs -n $NAMESPACE deployment/operator-controller-manager --tail=100 2>/dev/null)

# Count total log lines (excluding K8s info lines)
TOTAL_LINES=$(echo "$ALL_LOGS" | grep -v "^I" | grep -v "^$" | wc -l)

# Count valid JSON lines
VALID_JSON_LINES=$(echo "$ALL_LOGS" | grep -v "^I" | grep -v "^$" | while read line; do
    echo "$line" | jq -e '.level' >/dev/null 2>&1 && echo "1"
done | wc -l)

# Calculate percentage
if [ "$TOTAL_LINES" -gt 0 ]; then
    PERCENTAGE=$((VALID_JSON_LINES * 100 / TOTAL_LINES))
    if [ "$PERCENTAGE" -ge 90 ]; then
        pass_test "JSON structured logging verified ($PERCENTAGE% valid JSON)"
        info_log "Valid JSON lines: $VALID_JSON_LINES / $TOTAL_LINES"
    else
        info_log "JSON logging percentage: $PERCENTAGE% (valid: $VALID_JSON_LINES/$TOTAL_LINES)"
    fi
else
    info_log "No logs found to verify"
fi

# Verify required JSON fields
LOGS_WITH_LEVEL=$(echo "$ALL_LOGS" | grep -v "^I" | jq -e '.level' 2>/dev/null | wc -l)
LOGS_WITH_MESSAGE=$(echo "$ALL_LOGS" | grep -v "^I" | jq -e '.message' 2>/dev/null | wc -l)
info_log "Logs with 'level' field: $LOGS_WITH_LEVEL, with 'message' field: $LOGS_WITH_MESSAGE"

echo ""

# ============================================================================
