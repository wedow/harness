#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_done/10-save"

input='{"call_id":"c1","name":"bash","input":{},"result":"permission denied","error":true,"tool_calls":[]}'

out="$(echo "$input" | "$hook")"

# Assert message file has error flag and body
msg_file="${HARNESS_SESSION}/messages/0001-tool_result.md"
assert_file_exists "$msg_file"
assert_file_contains "$msg_file" "error: true"
assert_file_contains "$msg_file" "permission denied"

# Assert routing still works with error flag
assert_json '.next_state' "$out" "assemble"
