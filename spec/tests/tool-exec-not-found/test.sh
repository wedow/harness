#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_exec/10-exec"

# Source dir with no tools
mock_src="${_tmpdir}/mock_src"
mkdir -p "${mock_src}/tools"

# Need session.conf for cwd
echo "cwd=/tmp" > "${HARNESS_SESSION}/session.conf"

export HARNESS_SOURCES="${mock_src}"

out="$(echo '{"tool_calls":[{"id":"call_2","name":"nonexistent","input":{}}]}' | "$hook")"

assert_json '.error'      "$out" "true"
assert_json '.next_state' "$out" "tool_done"

# Result should mention "not found"
result="$(echo "$out" | jq -r '.result')"
[[ "$result" == *"not found"* ]] || { echo "FAIL: result should contain 'not found', got: $result"; exit 1; }
