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
[[ "${output}" == *"timed out after 1s"* ]] || { echo "FAIL: expected timeout marker, got: ${output}"; exit 1; }

# 2. Fast command completes within timeout
output=$(echo '{"command":"echo hello","timeout":5}' | "${tool}" --exec 2>&1)
assert_eq "fast-command" "$output" "hello"

# 3. Without per-call timeout, env var is used (fast command still works)
export HARNESS_TOOL_TIMEOUT=5
output=$(echo '{"command":"echo world"}' | "${tool}" --exec 2>&1)
assert_eq "env-timeout" "$output" "world"

# 4. Grandchildren are killed with the group: a hung background process
#    holding the output pipe must not outlive the timeout.
start=$SECONDS
output=$(echo '{"command":"sleep 987 & echo started; wait","timeout":1}' | "${tool}" --exec 2>&1)
elapsed=$(( SECONDS - start ))
assert_eq "grandchild-fast-return" "$(( elapsed < 8 ? 1 : 0 ))" "1"
[[ "${output}" == *"started"* ]] || { echo "FAIL: expected command output, got: ${output}"; exit 1; }
[[ "${output}" == *"timed out after 1s"* ]] || { echo "FAIL: expected timeout marker, got: ${output}"; exit 1; }
sleep 0.5
leftover="$(pgrep -c -f "sleep 987$" || true)"
assert_eq "no-orphan-grandchild" "${leftover}" "0"

echo "PASS"
