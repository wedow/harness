#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/anthropic/hooks.d/receive/10-save"

input='{"model":"claude-sonnet-4-20250514","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"thinking","thinking":"Let me reason...","signature":"sig123"},{"type":"text","text":"The answer is 42."}]}'

out="$(echo "$input" | "$hook")"

# Assert message file was created
msg="$(ls -1 "${HARNESS_SESSION}/messages/"*-assistant.md)"
assert_file_exists "$msg"

# Assert thinking block in body
assert_file_contains "$msg" '```thinking signature=sig123'
assert_file_contains "$msg" "Let me reason..."

# Assert control JSON
assert_json '.next_state' "$out" "done"
assert_json '.output' "$out" "The answer is 42."
