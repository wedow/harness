#!/usr/bin/env bash
# Test: 25-compact truncates large ChatGPT function_call_output content.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/assemble/25-compact"

big="$(printf 'z%.0s' $(seq 1 10000))"

payload="$(jq -n --arg big "${big}" '{
  messages: [
    {type: "message", role: "user", content: [{type: "input_text", text: "go"}]},
    {type: "function_call", name: "bash", arguments: "{}", call_id: "c1"},
    {type: "function_call_output", call_id: "c1", output: $big},
    {type: "message", role: "assistant", content: [{type: "output_text", text: "got it"}]},
    {type: "message", role: "user", content: [{type: "input_text", text: "next"}]},
    {type: "message", role: "assistant", content: [{type: "output_text", text: "ok"}]},
    {type: "message", role: "user", content: [{type: "input_text", text: "more"}]},
    {type: "message", role: "assistant", content: [{type: "output_text", text: "done"}]}
  ]
}')"

out="$(echo "${payload}" | RLM_COMPACT_TOTAL=5000 RLM_COMPACT_MESSAGE=3000 RLM_KEEP_RECENT=4 "${hook}")"

# function_call_output (index 2) should be truncated
tr_output="$(echo "${out}" | jq -r '.messages[2].output')"
echo "${tr_output}" | grep -q "truncated" || { echo "FAIL: output not truncated"; exit 1; }
echo "${tr_output}" | grep -q "10000 chars" || { echo "FAIL: original size not in breadcrumb"; exit 1; }

# Recent messages preserved
last="$(echo "${out}" | jq -r '.messages[7].content[0].text')"
assert_eq "recent message preserved" "${last}" "done"
