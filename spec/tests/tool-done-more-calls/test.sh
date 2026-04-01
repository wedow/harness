#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_done/10-save"

input='{"call_id":"c1","name":"bash","input":{"command":"ls"},"result":"file.txt","error":false,"tool_calls":[{"id":"c2","name":"bash","input":{"command":"pwd"}}]}'

out="$(echo "$input" | "$hook")"

# Assert message file exists and has correct content
msg_file="${HARNESS_SESSION}/messages/0001-tool_result.md"
assert_file_exists "$msg_file"
assert_file_contains "$msg_file" "call_id: c1"
assert_file_contains "$msg_file" "tool: bash"
assert_file_contains "$msg_file" "file.txt"

# Assert routing: more calls remain
assert_json '.next_state'          "$out" "tool_exec"
assert_json '.tool_calls | length' "$out" "1"
