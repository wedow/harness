#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/openai/hooks.d/receive/10-save"

input='{"model":"gpt-4","choices":[{"finish_reason":"stop","message":{"content":"Hello from OpenAI!","tool_calls":null}}],"usage":{"prompt_tokens":50,"completion_tokens":25,"total_tokens":75,"prompt_tokens_details":{"cached_tokens":40}}}'

out="$(echo "$input" | "$hook")"

# Assert message file was created
msg="$(ls -1 "${HARNESS_SESSION}/messages/"*-assistant.md)"
assert_file_exists "$msg"

# Assert frontmatter
assert_file_contains "$msg" "role: assistant"
assert_file_contains "$msg" "stop: end"
assert_file_contains "$msg" "tokens_in: 50"
assert_file_contains "$msg" "tokens_out: 25"
assert_file_contains "$msg" "tokens_total: 75"
assert_file_contains "$msg" "tokens_cache_read: 40"
assert_file_contains "$msg" "tokens_cache_write: 0"

# Assert body
assert_file_contains "$msg" "Hello from OpenAI!"

# Assert control JSON
assert_json '.next_state' "$out" "done"
assert_json '.output' "$out" "Hello from OpenAI!"
