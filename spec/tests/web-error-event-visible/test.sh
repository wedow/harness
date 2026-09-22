#!/usr/bin/env bash
# A failed agent turn must tell the user why it stopped, including on reconnect.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

sid=error-event-visible
dir="${HARNESS_SESSIONS}/${sid}"
mkdir -p "${dir}/messages"
printf '%s\n' '{"type":"error","message":"API failed: <retry> & inspect"}' > "${dir}/.stream"

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
  if [[ -f "${pushes}" ]] && grep -Fq 'API failed:' "${pushes}"; then break; fi
  sleep 0.1
done
grep -Fq 'API failed: &lt;retry&gt; &amp; inspect' "${pushes}" \
  || { echo 'FAIL: stream error was not shown safely in the live UI'; exit 1; }

printf '%s\n' '{"type":"error","message":""}' >> "${dir}/.stream"
for _ in {1..30}; do
  grep -Fq 'Agent run failed' "${pushes}" && break
  sleep 0.1
done
grep -Fq 'Agent run failed' "${pushes}" \
  || { echo 'FAIL: empty error lacked a useful fallback'; exit 1; }

echo PASS
