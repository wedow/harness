#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/anthropic/hooks.d/receive/10-save"

input='{"model":"claude-sonnet-4-20250514","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"text","text":"Hello, world!"}]}'

out="$(echo "$input" | "$hook")"

# Assert message file was created
msg="$(ls -1 "${HARNESS_SESSION}/messages/"*-assistant.md)"
assert_file_exists "$msg"

# Assert frontmatter fields
assert_file_contains "$msg" "role: assistant"
assert_file_contains "$msg" "stop: end"

# Assert body content
assert_file_contains "$msg" "Hello, world!"

# Assert control JSON
assert_json '.next_state' "$out" "done"
assert_json '.output' "$out" "Hello, world!"
