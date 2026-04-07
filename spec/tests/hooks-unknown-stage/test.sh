#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

# Nonexistent stage should fail with error
rc=0
stderr="$(bin/harness hooks nonexistent-stage 2>&1 >/dev/null)" || rc=$?
assert_eq "unknown-stage-exit-code" "$rc" "1"

# Valid stage should still work
rc=0
output="$(bin/harness hooks resolve 2>/dev/null)" || rc=$?
assert_eq "valid-stage-exit-code" "$rc" "0"
