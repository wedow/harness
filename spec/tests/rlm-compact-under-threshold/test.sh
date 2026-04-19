#!/usr/bin/env bash
# Test: 25-compact passes through unchanged when total content is under threshold.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/assemble/25-compact"

payload='{"messages":[{"role":"user","content":"hello"},{"role":"assistant","content":"hi"},{"role":"tool","tool_call_id":"t1","content":"short result"}]}'

out="$(echo "${payload}" | RLM_COMPACT_TOTAL=200000 RLM_COMPACT_MESSAGE=8000 "${hook}")"

# Nothing should be truncated
assert_json '.messages[2].content' "${out}" "short result"
assert_json '.messages[0].content' "${out}" "hello"
