#!/usr/bin/env bash
# A replaced stream that regrows past the prior offset must start at byte zero.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

sid=regrow
dir="${HARNESS_SESSIONS}/${sid}"
mkdir -p "${dir}/messages"
printf '%s\n' '---' 'role: user' 'seq: 0001' '---' 'go' > "${dir}/messages/0001-user.md"
export PUSHES="${_tmpdir}/pushes"

timeout 8 bash -c '
  source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
  source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"
  respond_sse() { :; }
  sse_patch() { printf "%s\n" "$1" >> "${PUSHES}"; }
  handle_events regrow
' &
hpid=$!
cleanup() { kill "${hpid}" 2>/dev/null || true; wait "${hpid}" 2>/dev/null || true; teardown; }
trap cleanup EXIT
sleep 0.8

padding="$(printf '%0180d' 0)"
printf '{"type":"thinking","text":"old-turn-%s"}\n' "${padding}" > "${dir}/.stream"
for _ in {1..20}; do
  grep -q 'old-turn' "${PUSHES}" 2>/dev/null && break
  sleep 0.1
done
grep -q 'old-turn' "${PUSHES}" 2>/dev/null || { echo 'FAIL: initial stream was not observed'; exit 1; }
old_size="$(stat -c %s "${dir}/.stream")"

# The handler is now waiting for its next poll. Truncate and regrow the same
# inode in one quick write, with a new turn larger than the prior offset.
new_stream="${_tmpdir}/new-stream"
printf '%s\n' '{"type":"thinking","text":"new-turn"}' > "${new_stream}"
head -c "${old_size}" /dev/zero | tr '\0' ' ' >> "${new_stream}"
printf '\n' >> "${new_stream}"
cat "${new_stream}" > "${dir}/.stream"
sleep 1.2
grep -q 'new-turn' "${PUSHES}" 2>/dev/null || {
  echo 'FAIL: new turn was lost when stream regrew past old offset'
  exit 1
}
