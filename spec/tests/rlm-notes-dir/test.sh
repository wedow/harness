#!/usr/bin/env bash
# Test: 05-notes start hook creates notes/ directory in the session.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/start/05-notes"

# Remove notes/ if it exists from setup
rmdir "${HARNESS_SESSION}/notes" 2>/dev/null || true

out="$(echo '{}' | "${hook}")"

# notes/ dir should exist
[[ -d "${HARNESS_SESSION}/notes" ]] || { echo "FAIL: notes/ not created"; exit 1; }

# Hook should pass through input unchanged
assert_json '.' "${out}" '{}'
