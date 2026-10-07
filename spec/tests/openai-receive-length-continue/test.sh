#!/usr/bin/env bash
# Test: openai-protocol stop:length continues the turn (shared lib parity with
# the anthropic hook). finish_reason=length must route to assemble with a
# nudge; cap and reset behave the same.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/openai/hooks.d/receive/10-save"
msg_dir="${HARNESS_SESSION}/messages"

resp() { # $1 = finish_reason
  jq -c -n --arg fr "$1" '{choices: [{finish_reason: $fr, message: {role: "assistant", content: "partial"}}],
    model: "m", usage: {prompt_tokens: 1, completion_tokens: 2, total_tokens: 3}}'
}

out="$(resp length | "${hook}")"
assert_json '.next_state' "${out}" "assemble"
nudge="$(ls "${msg_dir}" | grep -E '^[0-9]+-user\.md$' | tail -1)"
[[ -n "${nudge}" ]] || { echo "FAIL: no nudge saved"; exit 1; }
grep -q 'continuation: length' "${msg_dir}/${nudge}" || { echo "FAIL: nudge unmarked"; exit 1; }
assert_eq "counter" "$(cat "${HARNESS_SESSION}/.length_cont")" "1"

out="$(resp tool_calls | "${hook}")"
assert_json '.next_state' "${out}" "tool_exec"
[[ ! -f "${HARNESS_SESSION}/.length_cont" ]] || { echo "FAIL: counter not reset"; exit 1; }

out="$(resp stop | "${hook}")"
assert_json '.next_state' "${out}" "done"

echo "PASS"