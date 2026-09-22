#!/usr/bin/env bash
# A same-size message rewrite within one second must reach the live transcript.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSIONS="${_tmpdir}/sessions"
dir="${HARNESS_SESSIONS}/subsecond"
mkdir -p "${dir}/messages"
file="${dir}/messages/0001-user.md"
printf '%s\n' '---' 'role: user' 'seq: 0001' '---' 'alpha' > "${file}"
second="$(date +%s)"
touch -d "@${second}.100000000" "${file}"

timeout 5 bash -c "
  export HARNESS_SESSIONS='${HARNESS_SESSIONS}' HARNESS_ROOT='${HARNESS_ROOT}'
  source '${HARNESS_ROOT}/plugins/web/lib/http.sh'
  source '${HARNESS_ROOT}/plugins/web/lib/pages.sh'
  respond_sse() { :; }
  sse_patch() {
    case \"\$1\" in *'id=\"transcript\"'*|*'id=\"m0001\"'*) printf '%s' \"\$1\" | tr '\\n' ' ' >> '${_tmpdir}/pushes'; printf '\\n' >> '${_tmpdir}/pushes';; esac
    return 0
  }
  handle_events subsecond
" &
hpid=$!
sleep 0.8
[[ "$(wc -l < "${_tmpdir}/pushes")" == 1 ]] || { echo 'FAIL: missing initial transcript'; kill "$hpid" 2>/dev/null; exit 1; }

sed -i 's/alpha/bravo/' "${file}"
touch -d "@${second}.900000000" "${file}"
sleep 1.2
if [[ "$(wc -l < "${_tmpdir}/pushes")" != 2 ]] || ! tail -1 "${_tmpdir}/pushes" | grep -q bravo; then
  echo 'FAIL: same-size, same-second rewrite did not patch transcript'
  kill "$hpid" 2>/dev/null
  exit 1
fi

kill "$hpid" 2>/dev/null
wait "$hpid" 2>/dev/null || true
