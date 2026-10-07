#!/usr/bin/env bash
# web-live-thinking — thinking deltas from .stream render live in #live;
# the saved message's collapsed render supersedes (clears) the live block.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSIONS="${_tmpdir}/sessions"
sess="live"
dir="${HARNESS_SESSIONS}/${sess}"
mkdir -p "${dir}/messages"
printf -- '---\nrole: user\nseq: 0001\ntimestamp: 2026-09-21T08:00:00+00:00\n---\ngo\n' \
  > "${dir}/messages/0001-user.md"

timeout 10 bash -c "
  export HARNESS_SESSIONS='${HARNESS_SESSIONS}' HARNESS_ROOT='${HARNESS_ROOT}'
  source '${HARNESS_ROOT}/plugins/web/lib/http.sh'
  source '${HARNESS_ROOT}/plugins/web/lib/pages.sh'
  respond_sse() { :; }
  sse_patch() { printf '=== PUSH\n%s\n=== END\n' \"\$1\" >> '${_tmpdir}/pushes'; return 0; }
  handle_events '${sess}'
" &
hpid=$!
sleep 0.8

n() { grep -c '=== PUSH' "${_tmpdir}/pushes" 2>/dev/null || echo 0; }
last() { awk '/=== PUSH/{buf="";p=1;next} /=== END/{p=0;last=buf;next} p{buf=buf $0 "\n"} END{printf "%s",last}' "${_tmpdir}/pushes"; }

base="$(n)"

# 1. thinking deltas -> live push with open block and accumulated text
printf '{"type":"thinking","text":"pondering "}\n{"type":"thinking","text":"deeply"}\n' >> "${dir}/.stream"
sleep 1.2
last | grep -q 'pondering deeply' || { echo "FAIL: live text not accumulated/shown"; kill $hpid 2>/dev/null; exit 1; }
last | grep -q '<details class="seg think" open>' \
  || { echo "FAIL: live block not open"; kill $hpid 2>/dev/null; exit 1; }

# 2. more deltas -> updated live content (single morph target id)
printf '{"type":"thinking","text":" more"}\n' >> "${dir}/.stream"
sleep 1.2
last | grep -q 'pondering deeply more' || { echo "FAIL: live not updated"; kill $hpid 2>/dev/null; exit 1; }

# A newline-only delta must remain visible and trigger its own live patch.
before="$(n)"
printf '{"type":"thinking","text":"\\n"}\n' >> "${dir}/.stream"
sleep 1.2
[[ "$(n)" -gt "${before}" ]] \
  || { echo "FAIL: newline-only thinking delta sent no patch"; kill $hpid 2>/dev/null; exit 1; }
last | awk '/pondering deeply more$/{getline; if ($0 ~ /^<\/pre>/) found=1} END{exit !found}' \
  || { echo "FAIL: live thinking newline was lost"; kill $hpid 2>/dev/null; exit 1; }

# 3. message lands -> transcript delta AND live cleared
cat > "${dir}/messages/0002-assistant.md" <<'M'
---
role: assistant
seq: 0002
timestamp: 2026-09-21T08:00:05+00:00
stop: end
---
```thinking signature=s
pondering deeply more
```
Done thinking.
M
sleep 1.5
last | grep -q '^<div id="live"></div>$' || { echo "FAIL: live not cleared after message landed"; kill $hpid 2>/dev/null; exit 1; }
grep -q 'id="m0002"' "${_tmpdir}/pushes" || { echo "FAIL: message delta not pushed"; kill $hpid 2>/dev/null; exit 1; }

# 4. turn end -> full re-sync
printf '{"type":"done"}\n' >> "${dir}/.stream"
sleep 1.5
last | grep -q 'id="m0001"' || { echo "FAIL: no full sync on done"; kill $hpid 2>/dev/null; exit 1; }

kill $hpid 2>/dev/null
wait $hpid 2>/dev/null || true
