#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/start/10-init"

# Test: outputs next_state=assemble from empty input
out="$(echo '{}' | "$hook")"
assert_json '.next_state' "$out" "assemble"

# Test: with session.conf cwd, still outputs next_state=assemble
echo "cwd=/tmp/test" > "${HARNESS_SESSION}/session.conf"
out="$(echo '{}' | "$hook")"
assert_json '.next_state' "$out" "assemble"
