#!/usr/bin/env bash
# Test: agent status line shows queued messages and live subagents while a
# turn is in flight. Idle sessions show nothing; finished subagents (exit
# marker) and killed panes (no live process) are not counted.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

sessions="${_tmpdir}/sessions"
mkdir -p "${sessions}"
export HARNESS_SESSIONS="${sessions}"
source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"

sid="s1"; dir="${sessions}/${sid}"
mkdir -p "${dir}"

# Idle: no output, non-zero rc
line="$(_agent_status_line "${sid}" || true)"
assert_eq "idle status empty" "${line}" ""

# One live subagent: child session dir, no exit marker, live process whose
# cmdline references it (as `harness stream <id>` would).
mkdir -p "${dir}/.harness/sessions/sub-live" "${dir}/.harness/sessions/sub-done"
touch "${dir}/.harness/sessions/sub-done/.exit_code"
bash -c 'sleep 3; true # sessions/sub-live' &
sub_pid=$!

# Running driver (mid-turn messages are inserted into the transcript now,
# so the status line reports subagents only).
( exec 9>"${dir}/.lock"; flock 9; sleep 2 ) &
holder=$!
sleep 0.5

line="$(_agent_status_line "${sid}")"
[[ "${line}" == *"1 subagent"* ]] || { echo "FAIL: expected subagent in: ${line}"; kill ${holder} ${sub_pid} 2>/dev/null || true; exit 1; }
[[ "${line}" != *"2 subagent"* ]] || { echo "FAIL: counted finished subagent: ${line}"; kill ${holder} ${sub_pid} 2>/dev/null || true; exit 1; }

kill ${holder} ${sub_pid} 2>/dev/null || true
wait ${holder} 2>/dev/null || true

echo "PASS"