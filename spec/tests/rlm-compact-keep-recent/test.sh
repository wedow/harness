#!/usr/bin/env bash
# Test: 25-compact preserves the last N messages even when they contain large content.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/assemble/25-compact"

big="$(printf 'a%.0s' $(seq 1 10000))"

# Put large content in both an old message AND a recent message
payload="$(jq -n --arg big "${big}" '{
  messages: [
    {role: "user", content: $big},
    {role: "assistant", content: "ok"},
    {role: "user", content: "next"},
    {role: "tool", tool_call_id: "t2", content: $big}
  ]
}')"

# keep=2 means last 2 messages are protected
out="$(echo "${payload}" | RLM_COMPACT_TOTAL=5000 RLM_COMPACT_MESSAGE=3000 RLM_KEEP_RECENT=2 "${hook}")"

# Old message (index 0) should be truncated
old="$(echo "${out}" | jq -r '.messages[0].content')"
echo "${old}" | grep -q "truncated" || { echo "FAIL: old message not truncated"; exit 1; }

# Recent tool result (index 3, within last 2) should be preserved at full size
recent_len="$(echo "${out}" | jq -r '.messages[3].content | length')"
assert_eq "recent large content preserved" "${recent_len}" "10000"
