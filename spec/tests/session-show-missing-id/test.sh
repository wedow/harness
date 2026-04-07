#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

# Missing session ID should produce clean error (no internal path)
rc=0
stderr="$(bin/harness session show 2>&1 >/dev/null)" || rc=$?
assert_eq "missing-id-exit-code" "$rc" "1"

# Error should NOT contain internal script path
if [[ "$stderr" == *"plugins/core/commands/session"* ]]; then
  echo "FAIL: error exposes internal path: $stderr"
  exit 1
fi
