#!/usr/bin/env bash
# Test: 25-compact truncates large OpenAI tool result content.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/assemble/25-compact"

big="$(printf 'y%.0s' $(seq 1 10000))"

payload="$(jq -n --arg big "${big}" '{
  messages: [
    {role: "user", content: "do something"},
    {role: "assistant", tool_calls: [{id: "t1", type: "function", function: {name: "bash", arguments: "{}"}}]},
    {role: "tool", tool_call_id: "t1", content: $big},
    {role: "assistant", content: "noted"},
    {role: "user", content: "next"},
    {role: "assistant", content: "ok"},
    {role: "user", content: "more"},
    {role: "assistant", content: "done"}
  ]
}')"

out="$(echo "${payload}" | RLM_COMPACT_TOTAL=5000 RLM_COMPACT_MESSAGE=3000 RLM_KEEP_RECENT=4 "${hook}")"

# Tool result (index 2) should be truncated
tr_content="$(echo "${out}" | jq -r '.messages[2].content')"
echo "${tr_content}" | grep -q "truncated" || { echo "FAIL: tool content not truncated"; exit 1; }
echo "${tr_content}" | grep -q "10000 chars" || { echo "FAIL: original size not in breadcrumb"; exit 1; }

# Recent messages preserved
assert_json '.messages[7].content' "${out}" "done"
