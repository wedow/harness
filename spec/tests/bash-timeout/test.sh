#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

tool="${HARNESS_ROOT}/plugins/core/tools/bash"
export HARNESS_CWD="${_tmpdir}"

# 1. Per-call timeout kills a long-running command (no output, completes quickly)
start=$SECONDS
output=$(echo '{"command":"sleep 30","timeout":1}' | "${tool}" --exec 2>&1)
elapsed=$(( SECONDS - start ))
assert_eq "timeout-fast-return" "$(( elapsed < 5 ? 1 : 0 ))" "1"
assert_eq "timeout-no-output" "$output" ""

# 2. Fast command completes within timeout
output=$(echo '{"command":"echo hello","timeout":5}' | "${tool}" --exec 2>&1)
assert_eq "fast-command" "$output" "hello"

# 3. Without per-call timeout, env var is used (fast command still works)
export HARNESS_TOOL_TIMEOUT=5
output=$(echo '{"command":"echo world"}' | "${tool}" --exec 2>&1)
assert_eq "env-timeout" "$output" "world"
