#!/usr/bin/env bash
# An SSE reconnect during a running tool must not replay the thinking that
# preceded that tool call as a new, open thinking block.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSIONS="${_tmpdir}/sessions"
sid=thinking-tool-boundary
dir="${HARNESS_SESSIONS}/${sid}"
mkdir -p "${dir}/messages"
cat > "${dir}/messages/0001-user.md" <<'MSG'
---
role: user
seq: 0001
timestamp: 2026-09-22T20:00:00+00:00
---
start
MSG
printf '%s\n' \
  '{"type":"thinking","text":"reasoning before tool"}' \
  '{"type":"text","text":"Launching child"}' \
  '{"type":"tool_start","id":"call_1","name":"agent"}' \
  > "${dir}/.stream"

pushes="${_tmpdir}/pushes"
export PUSHES="${pushes}" SID="${sid}"
timeout 8 bash -c '
  source "$HARNESS_ROOT/plugins/web/lib/http.sh"
  source "$HARNESS_ROOT/plugins/web/lib/pages.sh"
  respond_sse() { :; }
  sse_patch() { printf "%s\n" "$1" >> "$PUSHES"; }
  handle_events "$SID"
' &
hpid=$!
trap 'kill "$hpid" 2>/dev/null || true; wait "$hpid" 2>/dev/null || true; teardown' EXIT

for _ in {1..30}; do
  [[ -f "${pushes}" ]] && break
  sleep 0.1
done
[[ -f "${pushes}" ]] || { echo 'FAIL: SSE handler did not start'; exit 1; }
sleep 0.8
if grep -Fq 'reasoning before tool' "${pushes}"; then
  echo 'FAIL: reconnect replayed pre-tool thinking as an open live block'
  exit 1
fi

# A new thinking delta after the boundary still appears live.
printf '%s\n' '{"type":"thinking","text":"fresh reasoning"}' >> "${dir}/.stream"
for _ in {1..30}; do
  grep -Fq 'fresh reasoning' "${pushes}" && break
  sleep 0.1
done
grep -Fq 'fresh reasoning' "${pushes}" || { echo 'FAIL: fresh thinking was not shown'; exit 1; }

echo PASS
