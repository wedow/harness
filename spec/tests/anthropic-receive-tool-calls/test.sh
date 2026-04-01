#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/anthropic/hooks.d/receive/10-save"

input='{"model":"claude-sonnet-4-20250514","stop_reason":"tool_use","usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"text","text":"Let me check."},{"type":"tool_use","id":"toolu_123","name":"bash","input":{"command":"ls"}}]}'

out="$(echo "$input" | "$hook")"

# Assert message file was created
msg="$(ls -1 "${HARNESS_SESSION}/messages/"*-assistant.md)"
assert_file_exists "$msg"

# Assert frontmatter
assert_file_contains "$msg" "stop: tool_calls"

# Assert body content
assert_file_contains "$msg" "Let me check."
assert_file_contains "$msg" '```tool_call id=toolu_123 name=bash'

# Assert control JSON
assert_json '.next_state' "$out" "tool_exec"
assert_json '.tool_calls[0].name' "$out" "bash"
assert_json '.tool_calls[0].id' "$out" "toolu_123"
assert_json '.tool_calls[0].input.command' "$out" "ls"
