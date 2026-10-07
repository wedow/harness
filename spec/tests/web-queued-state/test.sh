#!/usr/bin/env bash
# A message inserted during a running turn is visible immediately, but the
# status must also say that the agent has not read it yet. The notice clears
# only after an assemble records the message's sequence number.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSIONS="${_tmpdir}/sessions"
mkdir -p "${HARNESS_SESSIONS}"
source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"

sid="20260101-000000-1"
dir="${HARNESS_SESSIONS}/${sid}"
mkdir -p "${dir}/messages"

# Keep the status probe deterministic: the test concerns message state, not
# process discovery or subagent counting.
_driver_alive() { return 0; }
_subagent_count() { printf '0\n'; }

assert_waiting() {
  local expected="$1" status
  status="$(_agent_status_line "${sid}")"
  [[ "${status}" == *"${expected} queued"* ]] || {
    echo "FAIL: expected ${expected} queued message(s) in status: ${status}" >&2
    exit 1
  }
  [[ "${status}" == *waiting* ]] || {
    echo "FAIL: queued status does not explain that the message is waiting: ${status}" >&2
    exit 1
  }
  [[ "$(_status_fragment "${sid}")" == *"${expected} queued"* ]] || {
    echo "FAIL: live status fragment omitted queued message count" >&2
    exit 1
  }
}

_insert_live_message "${dir}" "first instruction"
first="$(basename "${dir}/messages/"*-user.md)"
first="${first%%-*}"
assert_waiting 1

_insert_live_message "${dir}" "second instruction"
assert_waiting 2

printf '%s\n' "${first}" > "${dir}/.assembled_user_seqs"
assert_waiting 1

for file in "${dir}/messages/"*-user.md; do
  seq="${file##*/}"
  seq="${seq%%-*}"
  printf '%s\n' "${seq}"
done > "${dir}/.assembled_user_seqs"
status="$(_agent_status_line "${sid}")"
[[ "${status}" != *queued* && "${status}" != *waiting* ]] || {
  echo "FAIL: status still reports a queued message after both were assembled: ${status}" >&2
  exit 1
}

echo PASS
