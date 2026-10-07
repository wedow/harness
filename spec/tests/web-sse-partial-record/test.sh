#!/usr/bin/env bash
# A JSONL record split across writes must be shown once its newline arrives.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

sid=partial
dir="${HARNESS_SESSIONS}/${sid}"
mkdir -p "${dir}/messages"
printf '%s\n' '---' 'role: user' 'seq: 0001' '---' 'go' > "${dir}/messages/0001-user.md"
export PUSHES="${_tmpdir}/pushes"

timeout 8 bash -c '
  source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
  source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"
  respond_sse() { :; }
  sse_patch() { printf "%s\n" "$1" >> "${PUSHES}"; }
  handle_events partial
' &
hpid=$!
cleanup() { kill "${hpid}" 2>/dev/null || true; wait "${hpid}" 2>/dev/null || true; teardown; }
trap cleanup EXIT
sleep 0.8

printf '%s' '{"type":"thinking","text":"split' > "${dir}/.stream"
sleep 0.8 # handler observes the incomplete record before it is finished
printf '%s\n' ' event"}' >> "${dir}/.stream"
sleep 1.2
grep -q 'split event' "${PUSHES}" 2>/dev/null || {
  echo 'FAIL: completed JSONL record was lost after a partial write'
  exit 1
}
