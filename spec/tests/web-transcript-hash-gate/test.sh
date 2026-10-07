#!/usr/bin/env bash
# web-transcript-hash-gate — .stream-only churn must not patch messages;
# a real message change must.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSIONS="${_tmpdir}/sessions"
sess="hashgate"
dir="${HARNESS_SESSIONS}/${sess}"
mkdir -p "${dir}/messages"
cat > "${dir}/messages/0001-user.md" <<'M'
---
role: user
seq: 0001
timestamp: 2026-09-21T06:00:00+00:00
---
hello
M

source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"
respond_sse() { :; }
pushes=0
sse_patch() {
  [[ "$1" == *'id="transcript"'* || "$1" == *'id="m'[0-9]* ]] && pushes=$((pushes + 1))
  return 0
}

# writer: 2s of .stream-only churn, then a real message, then idle
(
  for i in $(seq 1 10); do printf '{"type":"text","text":"x"}\n' >> "${dir}/.stream"; sleep 0.2; done
  cat > "${dir}/messages/0002-user.md" <<'M'
---
role: user
seq: 0002
timestamp: 2026-09-21T06:00:03+00:00
---
real change
M
  sleep 1
) &
wpid=$!

timeout 5 bash -c "
  export HARNESS_SESSIONS='${HARNESS_SESSIONS}' HARNESS_ROOT='${HARNESS_ROOT}'
  source '${HARNESS_ROOT}/plugins/web/lib/http.sh'
  source '${HARNESS_ROOT}/plugins/web/lib/pages.sh'
  respond_sse() { :; }
  sse_patch() {
    [[ \"\$1\" == *'id=\"transcript\"'* || \"\$1\" == *'id=\"m'[0-9]* ]] && echo PUSH >> '${_tmpdir}/pushes'
    return 0
  }
  handle_events '${sess}'
" || true
wait $wpid 2>/dev/null || true

n="$(wc -l < "${_tmpdir}/pushes" 2>/dev/null | tr -d ' ' || echo 0)"
n="${n:-0}"
# exactly 2: initial sync + the real message change (churn sends nothing)
if [[ "${n}" != "2" ]]; then
  echo "FAIL: expected 2 message patches (initial + real change), got ${n}"
  exit 1
fi
