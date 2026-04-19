#!/usr/bin/env bash
# Test: 25-compact truncates large Anthropic tool_result content with breadcrumbs.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/assemble/25-compact"

# Generate a large string (10K chars)
big="$(printf 'x%.0s' $(seq 1 10000))"

# Build Anthropic-format payload with 8 messages, one containing a large tool_result
payload="$(jq -n --arg big "${big}" '{
  messages: [
    {role: "user", content: "read that file"},
    {role: "assistant", content: [{type: "text", text: "ok"}]},
    {role: "user", content: [{type: "tool_result", tool_use_id: "t1", content: $big}]},
    {role: "assistant", content: [{type: "text", text: "got it"}]},
    {role: "user", content: "now what"},
    {role: "assistant", content: [{type: "text", text: "let me think"}]},
    {role: "user", content: "ok"},
    {role: "assistant", content: [{type: "text", text: "done"}]}
  ]
}')"

# Use low thresholds to trigger compaction
out="$(echo "${payload}" | RLM_COMPACT_TOTAL=5000 RLM_COMPACT_MESSAGE=3000 RLM_KEEP_RECENT=4 "${hook}")"

# The tool_result (message index 2) should be truncated
tr_content="$(echo "${out}" | jq -r '.messages[2].content[0].content')"
echo "${tr_content}" | grep -q "truncated" || { echo "FAIL: tool_result not truncated"; exit 1; }
echo "${tr_content}" | grep -q "10000 chars" || { echo "FAIL: original size not in breadcrumb"; exit 1; }
echo "${tr_content}" | grep -q "messages/" || { echo "FAIL: session path not in breadcrumb"; exit 1; }

# Recent messages (last 4) should be untouched
last_content="$(echo "${out}" | jq -r '.messages[7].content[0].text')"
assert_eq "recent message preserved" "${last_content}" "done"
