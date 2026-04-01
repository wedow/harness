#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/openai/hooks.d/receive/10-save"

input='{"model":"gpt-4","choices":[{"finish_reason":"tool_calls","message":{"content":"","tool_calls":[{"id":"call_abc","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"/tmp/test\"}"}}]}}],"usage":{"prompt_tokens":50,"completion_tokens":25}}'

out="$(echo "$input" | "$hook")"

# Assert message file was created
msg="$(ls -1 "${HARNESS_SESSION}/messages/"*-assistant.md)"
assert_file_exists "$msg"

# Assert frontmatter
assert_file_contains "$msg" "stop: tool_calls"

# Assert body has tool_call block
assert_file_contains "$msg" '```tool_call id=call_abc name=read_file'

# Assert control JSON
assert_json '.next_state' "$out" "tool_exec"
assert_json '.tool_calls[0].name' "$out" "read_file"
assert_json '.tool_calls[0].id' "$out" "call_abc"
assert_json '.tool_calls[0].input.path' "$out" "/tmp/test"
