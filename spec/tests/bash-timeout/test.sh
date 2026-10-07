#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

tool="${HARNESS_ROOT}/plugins/core/tools/bash"
export HARNESS_CWD="${_tmpdir}"

# 1. Per-call timeout kills a long-running command (fast return, timed_out flag)
start=$SECONDS
output=$(echo '{"command":"sleep 30","timeout":1}' | "${tool}" --exec 2>&1)
elapsed=$(( SECONDS - start ))
assert_eq "timeout-fast-return" "$(( elapsed < 5 ? 1 : 0 ))" "1"
assert_json '.timed_out' "${output}" "true"
assert_json '.timeout_s' "${output}" "1"

# 2. Fast command completes within timeout; result is JSON with fields
output=$(echo '{"command":"echo hello","timeout":5}' | "${tool}" --exec 2>&1)
assert_json '.stdout' "${output}" "hello"
assert_json '.exit' "${output}" "0"
assert_json '.timed_out' "${output}" "false"
assert_json '.timeout_s' "${output}" "5"

# 3. Without per-call timeout, env var is used (fast command still works)
export HARNESS_TOOL_TIMEOUT=5
output=$(echo '{"command":"echo world"}' | "${tool}" --exec 2>&1)
assert_json '.stdout' "${output}" "world"
assert_json '.timeout_s' "${output}" "5"

# 3b. Non-zero exit code and stderr are reported in their own fields
output=$(echo '{"command":"echo out; echo bad >&2; exit 3"}' | "${tool}" --exec 2>&1)
assert_json '.exit' "${output}" "3"
assert_json '.stdout' "${output}" "out"
assert_json '.stderr' "${output}" "bad"

# 3c. elapsed_s is a plausible positive number
echo "${output}" | jq -e '.elapsed_s and (.elapsed_s | type == "number")' >/dev/null \
  || { echo "FAIL: elapsed_s not populated: ${output}"; exit 1; }

# 4. Grandchildren are killed with the group: a hung background process
#    holding the output pipe must not outlive the timeout.
start=$SECONDS
output=$(echo '{"command":"sleep 987 & echo started; wait","timeout":1}' | "${tool}" --exec 2>&1)
elapsed=$(( SECONDS - start ))
assert_eq "grandchild-fast-return" "$(( elapsed < 8 ? 1 : 0 ))" "1"
assert_json '.stdout' "${output}" "started"
assert_json '.timed_out' "${output}" "true"
sleep 0.5
leftover="$(pgrep -c -f "sleep 987$" || true)"
assert_eq "no-orphan-grandchild" "${leftover}" "0"

echo "PASS"