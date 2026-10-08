#!/usr/bin/env bash
# Real socat connections and a temporary durable journal; no model calls.
# shellcheck disable=SC1091,SC2154,SC2016
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
HARNESS_ROOT="$(cd "${HARNESS_ROOT}" && pwd)"; export HARNESS_ROOT
source "${HARNESS_ROOT}/lib/bootstrap.sh"
source "${HARNESS_ROOT}/lib/store.sh"
store_init
server=''; client=''; queue_owner=''; component_pid=''
groups=(); clients=()
cleanup_streams() {
  local pid
  for pid in "${clients[@]}" "${queue_owner}" "${component_pid}"; do
    [[ -n "${pid}" ]] || continue
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  for pid in "${groups[@]}"; do
    kill -CONT -- "-${pid}" 2>/dev/null || true
    kill -TERM -- "-${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  teardown
}
trap cleanup_streams EXIT
wait_for() {
  local label="$1" count
  shift
  for ((count=0;count<200;count++)); do
    if "$@" 2>/dev/null; then return 0; fi
    sleep .05
  done
  printf 'FAIL: timed out waiting for %s\n' "${label}" >&2
  cat "${_tmpdir}/server.log" >&2
  return 1
}
frames() { sed -n 's/^data: signals //p' "$1" | jq -c '._chatFeed|fromjson'; }
at_least() { [[ "$(frames "$1" | jq -s 'length')" -ge "$2" ]]; }
has_event() { frames "$1" | jq -se --argjson seq "$2" 'any(.[];any(.events[];.seq==$seq))' >/dev/null; }
has_status() { frames "$1" | jq -se "any(.[]; $2)" >/dev/null; }
stopped() { ! process_alive "$1"; }
no_children() { ! pgrep -P "$1" >/dev/null; }
start_server() {
  setsid bash -c 'exec 5>"${HARNESS_DATA}/locks/inherited-component"; flock 5; exec "${HARNESS_ROOT}/plugins/web/commands/serve" "$1"' bash "${port}" >"${_tmpdir}/server.log" 2>&1 & server=$!
  groups+=("${server}")
  wait_for 'web listener' curl -fsS --max-time 1 "http://127.0.0.1:${port}/api/status" -o /dev/null
}
open_stream() {
  local name="$1" path="$2"
  shift 2
  curl -NsS --max-time 60 -D "${_tmpdir}/${name}.headers" "$@" "http://127.0.0.1:${port}${path}" >"${_tmpdir}/${name}" 2>"${_tmpdir}/${name}.error" & client=$!
  clients+=("${client}")
  wait_for "${name} initial frame" at_least "${_tmpdir}/${name}" 1
}
status_code() { curl -sS --max-time 3 -o "${_tmpdir}/guard-body" -w '%{http_code}' "$@" "http://127.0.0.1:${port}/api/stream"; }

# Choose a port in a temporary test server; Python is test-only, not a runtime dependency.
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
start_server
open_stream empty '/api/stream?after=0&datastar=%7B%7D' -H 'Accept-Encoding: gzip'
headers="${_tmpdir}/empty.headers"
grep -q '^HTTP/1.1 200 ' "${headers}"
grep -qi '^Content-Type: text/event-stream' "${headers}"
grep -qi '^Cache-Control: .*no-store' "${headers}"
grep -qi '^X-Accel-Buffering: no' "${headers}"
if grep -qiE '^Content-(Length|Encoding):' "${headers}"; then echo 'FAIL: stream is buffered or compressed' >&2; exit 1; fi
frames "${_tmpdir}/empty" | jq -se 'length==1 and .[0].events==[] and .[0].cursor==0' >/dev/null
idle_bytes="$(wc -c < "${_tmpdir}/empty")"
sleep 1.2
assert_eq 'idle connection sends no repeated network frames' "$(wc -c < "${_tmpdir}/empty")" "${idle_bytes}"
# The stream must never own the journal lock while waiting on a socket.
flock -n "${HARNESS_DATA}/locks/journal" true
store_emit message main '{"kind":"user","text":"first complete message ✓"}' first >/dev/null
store_emit request.queued main '{"id":"internal"}' bookkeeping >/dev/null
store_emit message child-one '{"kind":"user","text":"child-only history"}' child-only >/dev/null
store_emit assistant main '{"text":"complete reply"}' reply >/dev/null
wait_for 'forward delivery from cursor zero' has_event "${_tmpdir}/empty" 4
frames "${_tmpdir}/empty" | jq -se '[.[].events[].seq]==[1,4] and .[-1].cursor==4' >/dev/null
kill -TERM "${client}"; wait "${client}" 2>/dev/null || true
wait_for 'disconnected handler cleanup' no_children "${server}"

# A reconnect header takes precedence over the URL cursor and retains UTF-8/text.
open_stream replay '/api/stream?after=999&datastar=%7B%7D' -H 'Last-Event-ID: 000000000001'
frames "${_tmpdir}/replay" | jq -se '.[0].events|length==1 and .[0].seq==4' >/dev/null
handler_pid="$(pgrep -P "${server}" | head -1)"
payload=$'UTF-8 漢😀\n\nevent: forged\ndata: forged'
store_emit message main "$(printf '%s' "${payload}" | jq -Rs '{kind:"echo",text:.}')" echo >/dev/null
wait_for 'new committed message' has_event "${_tmpdir}/replay" 5
frames "${_tmpdir}/replay" | jq -se --arg text "${payload}" 'any(.[];any(.events[];.seq==5 and .data.text==$text))' >/dev/null

# Status-only projection/queue changes are pushed at the same journal cursor.
jq '.actors.main.status="waiting_memory"' "${HARNESS_DATA}/state.json" | atomic_write "${HARNESS_DATA}/state.json"
wait_for 'projection status-only patch' has_status "${_tmpdir}/replay" '.events==[] and .cursor==5 and .status.actors[0].status=="waiting_memory"'
jq -cn '{id:"test-request"}' | atomic_write "${HARNESS_DATA}/queue/requests/0-turn/test-request.json"
wait_for 'queued request status' has_status "${_tmpdir}/replay" '.events==[] and .status.requests.queued==1'
flock -F "${HARNESS_DATA}/locks/request-test-request" sleep 40 & queue_owner=$!
wait_for 'lock-only running request status' has_status "${_tmpdir}/replay" '.events==[] and .status.requests.running==1'
sleep 40 & component_pid=$!
jq -cn --argjson pid "${component_pid}" --arg start "$(process_start "${component_pid}")" '{pid:$pid,start:$start}' | atomic_write "${HARNESS_DATA}/components/reactor.json"
wait_for 'live component status' has_status "${_tmpdir}/replay" '.events==[] and .status.components.reactor==true'
kill -TERM "${component_pid}"; wait "${component_pid}" 2>/dev/null || true; component_pid=''
wait_for 'PID-only component death status' has_status "${_tmpdir}/replay" '.events==[] and .status.components.reactor==false'

# An event file published before HEAD is still uncommitted and cannot be sent.
staged="$(jq -cn '{seq:6,id:"staged",actor:"main",kind:"assistant",data:{text:"published only after HEAD"},date:"2026-10-08T00:00:00Z"}')"
printf '%s' "${staged}" | atomic_write "${HARNESS_DATA}/events/000000000006.json"
sleep .7
if has_event "${_tmpdir}/replay" 6; then echo 'FAIL: uncommitted event leaked' >&2; exit 1; fi
printf '6\n' | atomic_write "${HARNESS_DATA}/index/staged"
printf '6\n' | atomic_write "${HARNESS_DATA}/HEAD"
wait_for 'HEAD commits the staged event' has_event "${_tmpdir}/replay" 6

# Listener restart ends its connection, releases inherited locks, and replays
# only messages after the browser's last fully received event ID.
kill -TERM "${server}"; wait "${server}" 2>/dev/null || true
flock -n "${HARNESS_DATA}/locks/inherited-component" true
wait_for 'handler exits with its listener' stopped "${handler_pid}"
wait_for 'client observes ended stream' stopped "${client}"
wait "${client}" 2>/dev/null || true
store_emit assistant main '{"text":"reply while disconnected"}' disconnected-reply >/dev/null
start_server
open_stream restarted '/api/stream?after=0' -H 'Last-Event-ID: 6'
frames "${_tmpdir}/restarted" | jq -se '.[0].events|length==1 and .[0].seq==7' >/dev/null
kill -TERM "${client}"; wait "${client}" 2>/dev/null || true

# Backlog batches acknowledge their own end, rather than the final journal HEAD.
for number in {1..105}; do
  store_emit assistant main "$(jq -cn --argjson n "${number}" '{text:("backlog "+($n|tostring))}')" "backlog-${number}" >/dev/null
done
store_emit request.completed main '{"id":"skipped-tail"}' skipped-tail >/dev/null
open_stream backlog '/api/stream?after=7'
wait_for 'all forward backlog batches' has_event "${_tmpdir}/backlog" 112
frames "${_tmpdir}/backlog" | jq -se '.[0].cursor==107 and .[0].has_more and (.[0].events|length)==100 and
  .[1].cursor==113 and (.[1].events|length)==5 and .[1].has_more==false and
  [.[].events[].seq]==[range(8;113)]' >/dev/null
assert_eq 'SSE ids equal each complete delivered batch cursor' "$(sed -n 's/^id: //p' "${_tmpdir}/backlog" | jq -cs '.')" "$(frames "${_tmpdir}/backlog" | jq -cs 'map(.cursor)')"
sed -n 's/^data: signals //p' "${_tmpdir}/backlog" | jq -se 'all(.[];keys==["_chatFeed"] and (._chatFeed|type)=="string")' >/dev/null
kill -TERM "${client}"; wait "${client}" 2>/dev/null || true

# Stream access uses the same exact Host/Origin checks as message submission.
assert_eq 'foreign stream Origin is rejected' "$(status_code -H 'Origin: https://evil.example')" 403
assert_eq 'foreign stream Fetch-Site is rejected' "$(status_code -H 'Sec-Fetch-Site: cross-site')" 403
assert_eq 'foreign stream Host is rejected' "$(status_code -H 'Host: attacker.example')" 403
for query in 'after=bad' 'after=1234567890123' 'after=1&after=2' 'datastar=x&datastar=y' 'unknown=x'; do
  assert_eq "invalid stream query ${query}" "$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/api/stream?${query}")" 400
done
assert_eq 'invalid reconnect header is rejected' "$(status_code -H 'Last-Event-ID: not-a-number')" 400
printf 'allowed_origins=https://agent.example\n' > "${HARNESS_HOME}/web.conf"
open_stream proxy '/api/stream' -H 'Origin: https://agent.example'
kill -TERM "${client}"; wait "${client}" 2>/dev/null || true
assert_eq 'origin matching is exact' "$(status_code -H 'Origin: https://agent.example.evil')" 403

# A burst after the initial empty frame must be replayed from zero forwards.
# Pause this temporary connection so the entire backlog is committed before
# the next read; newest-page semantics would silently lose its first records.
kill -TERM "${server}"; wait "${server}" 2>/dev/null || true
HARNESS_DATA="${_tmpdir}/empty-burst-data"; export HARNESS_DATA
store_init
start_server
open_stream empty_burst '/api/stream?after=0'
handler_pid="$(pgrep -P "${server}" | head -1)"
kill -STOP "${handler_pid}"
for number in {1..105}; do
  store_emit assistant main "$(jq -cn --argjson n "${number}" '{text:("empty burst "+($n|tostring))}')" "empty-burst-${number}" >/dev/null
done
kill -CONT "${handler_pid}"
wait_for 'all messages after empty initial frame' has_event "${_tmpdir}/empty_burst" 105
frames "${_tmpdir}/empty_burst" | jq -se '.[0].cursor==0 and .[0].events==[] and
  .[1].cursor==100 and .[1].has_more and (.[1].events|length)==100 and
  .[2].cursor==105 and .[2].has_more==false and (.[2].events|length)==5 and
  [.[].events[].seq]==[range(1;106)]' >/dev/null
printf 'PASS: Datastar SSE replay, complete batches, quiet idle, live status, disconnect/restart, and origin guards\n'
