#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_done/10-save"

input='{"call_id":"c1","name":"bash","input":{},"result":"done","error":false,"tool_calls":[]}'

out="$(echo "$input" | "$hook")"

# Assert message file saved
msg_file="${HARNESS_SESSION}/messages/0001-tool_result.md"
assert_file_exists "$msg_file"

# Assert routing: no more calls, go to assemble
assert_json '.next_state' "$out" "assemble"

# Should not have tool_calls key with items
remaining="$(echo "$out" | jq '.tool_calls // empty')"
assert_eq "no tool_calls" "$remaining" ""
