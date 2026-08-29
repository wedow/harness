#!/usr/bin/env bash
# Test: stop_reason max_tokens ("stop: length") continues the turn instead of
# ending it on a truncated message. The receive hook saves a synthetic nudge
# user message and routes back to assemble; continuations are capped
# (HARNESS_LENGTH_CONTINUATIONS, default 2); the counter resets on a fresh
# turn (tool_calls) or turn completion (end).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/anthropic/hooks.d/receive/10-save"
msg_dir="${HARNESS_SESSION}/messages"

resp() { # $1 = stop_reason
  jq -c -n --arg s "$1" '{stop_reason: $s, model: "m",
    usage: {input_tokens: 1, output_tokens: 2},
    content: [{type: "text", text: "partial answer"}]}'
}

# 1. First length hit: nudge saved, routes to assemble.
out="$(resp max_tokens | "${hook}")"
assert_json '.next_state' "${out}" "assemble"
nudge="$(ls "${msg_dir}" | grep -E '^[0-9]+-user\.md$' | tail -1)"
[[ -n "${nudge}" ]] || { echo "FAIL: no nudge message saved"; exit 1; }
grep -q 'continuation: length' "${msg_dir}/${nudge}" || { echo "FAIL: nudge unmarked"; exit 1; }
grep -q 'Continue exactly where you left off' "${msg_dir}/${nudge}" || { echo "FAIL: nudge text"; exit 1; }
assert_eq "counter" "$(cat "${HARNESS_SESSION}/.length_cont")" "1"

# 2. Second length hit: still within default cap of 2.
out="$(resp max_tokens | "${hook}")"
assert_json '.next_state' "${out}" "assemble"
assert_eq "counter" "$(cat "${HARNESS_SESSION}/.length_cont")" "2"

# 3. Third hit exceeds the cap: loud error, non-zero rc.
rc=0
out="$(resp max_tokens | "${hook}")" || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: cap must fail loudly, got: ${out}"; exit 1; }
assert_json '.error' "${out}" "output token limit hit 3 times (continuation cap 2); turn aborted"

# 4. Counter resets when a fresh turn starts (tool_calls) and on end.
resp tool_use | "${hook}" >/dev/null
[[ ! -f "${HARNESS_SESSION}/.length_cont" ]] || { echo "FAIL: counter not reset by tool_calls"; exit 1; }
echo 2 > "${HARNESS_SESSION}/.length_cont"
out="$(resp end_turn | "${hook}")"
assert_json '.next_state' "${out}" "done"
[[ ! -f "${HARNESS_SESSION}/.length_cont" ]] || { echo "FAIL: counter not reset by end"; exit 1; }

echo "PASS"