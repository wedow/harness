#!/usr/bin/env bash
# A mid-turn user message does not end the assistant's current thinking stream.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

sid=thinking-message-boundary
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
printf '%s\n' '{"type":"thinking","text":"ongoing thought"}' > "${dir}/.stream"

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
  [[ -f "${pushes}" ]] && grep -Fq 'ongoing thought' "${pushes}" && break
  sleep 0.1
done
grep -Fq 'ongoing thought' "${pushes}" || { echo 'FAIL: initial thinking was not shown'; exit 1; }

cat > "${dir}/messages/0002-user.md" <<'MSG'
---
role: user
seq: 0002
timestamp: 2026-09-22T20:00:01+00:00
---
mid-turn guidance
MSG
for _ in {1..30}; do
  grep -Fq 'mid-turn guidance' "${pushes}" && break
  sleep 0.1
done
grep -Fq 'mid-turn guidance' "${pushes}" || { echo 'FAIL: new user message was not shown'; exit 1; }

live="$(grep -F 'id="live"' "${pushes}" | tail -1)"
[[ "${live}" == *'ongoing thought'* ]] \
  || { echo 'FAIL: unrelated user message cleared live thinking'; exit 1; }

echo PASS
