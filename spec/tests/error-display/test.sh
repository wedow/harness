#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/error/10-display"

# Test: error message is surfaced in output
out="$(echo '{"error":"something broke"}' | "$hook")"
assert_json '.output' "$out" "error: something broke"

# Test: missing error field uses fallback message
out="$(echo '{}' | "$hook")"
echo "$out" | jq -r '.output' | grep -q "^error: " || { echo "FAIL: output should start with 'error: '"; exit 1; }
