#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
export HARNESS_HOME="${_tmpdir}/config" HARNESS_DATA="${_tmpdir}/data" HARNESS_CWD="${_tmpdir}" HARNESS_LIVE_ROOT="${HARNESS_ROOT}"
export HARNESS_PROVIDER=fixture HARNESS_MODEL=fixture HARNESS_WORKERS=2 HARNESS_RETRY_DELAY=0.05
export HARNESS_SERVE_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export FIXTURE_REQUEST_LOG="${_tmpdir}/calls" FIXTURE_SIDE_EFFECT="${_tmpdir}/effect" FIXTURE_GATE="${_tmpdir}/gate" FIXTURE_COUNTER="${_tmpdir}/counter" FIXTURE_TOOL_GATE="${_tmpdir}/tool-gate"
mkdir -p "${HARNESS_HOME}/providers"
cp "${HARNESS_ROOT}/spec/fixtures/provider" "${HARNESS_HOME}/providers/fixture"
source "${HARNESS_ROOT}/lib/bootstrap.sh"
source "${HARNESS_ROOT}/lib/store.sh"
source "${HARNESS_ROOT}/lib/services.sh"
store_init
cleanup_runtime() {
  service_stop all || true
  for lease in "${HARNESS_DATA}/jobs/"*/lease.json "${HARNESS_DATA}/requests/"*/lease.json; do
    [[ -f "${lease}" ]] || continue
    pid="$(jq -r '.pid' "${lease}")"; start="$(jq -r '.start' "${lease}")"
    process_alive "${pid}" "${start}" && kill -TERM -- "-${pid}" 2>/dev/null || true
  done
  teardown
}
trap cleanup_runtime EXIT
wait_state() {
  local query="$1" n
  for (( n=0;n<400;n++ )); do
    jq -e "${query}" "${HARNESS_DATA}/state.json" >/dev/null && return 0
    sleep .05
  done
  cat "${HARNESS_DATA}/state.json" >&2
  cat "${HARNESS_DATA}/logs/reactor.log" >&2
  printf 'FAIL: timed out: %s\n' "${query}" >&2; return 1
}
wait_file() {
  local file="$1" n
  for (( n=0;n<400;n++ )); do [[ -f "${file}" ]] && return 0; sleep .05; done
  printf 'FAIL: missing %s\n' "${file}" >&2; return 1
}
wait_lines() {
  local file="$1" expected="$2" n
  for (( n=0;n<400;n++ )); do
    [[ -f "${file}" ]] && (( $(wc -l <"${file}")>=expected )) && return 0
    sleep .05
  done
  printf 'FAIL: missing %s lines in %s\n' "${expected}" "${file}" >&2; return 1
}
service_start reactor
service_start worker-1
service_start worker-2
service_start web
for ((n=0;n<100;n++)); do
  curl -fsS "http://127.0.0.1:${HARNESS_SERVE_PORT}/api/status" >"${_tmpdir}/http-status" 2>/dev/null && break
  sleep .05
done

# Tool completion wakes the actor, is logged once, and executes only once.
curl -fsS -H 'Content-Type: application/json' --data '{"text":"launch tool","id":"tool-message"}' "http://127.0.0.1:${HARNESS_SERVE_PORT}/api/messages" >"${_tmpdir}/http-ack"
assert_json '.seq' "$(cat "${_tmpdir}/http-ack")" 1
wait_state '.actors.main.last_reply=="I received the finished work." and .actors.main.request==null and .actors.main.inbox==[]'
assert_eq 'tool executes once' "$(cat "${FIXTURE_SIDE_EFFECT}")" ran
feed="$(store_feed)"
assert_json '[.events[]|select(.kind=="message" and .data.kind=="echo")]|length' "${feed}" 1
assert_json '[.events[]|select(.kind=="tool")]|length' "${feed}" 1
assert_json '[.events[]|select(.kind=="assistant")|.data.text]==["I am starting the command.","I received the finished work."]' "${feed}" true
assert_json '[.events[]|select(.kind=="assistant" or .kind=="tool" or .data.kind=="echo")|.kind]==["assistant","tool","message","assistant"]' "${feed}" true
assert_eq 'launch and completion need only two model calls' "$(jq -s '[.[]|select(.kind=="request.queued" and .data.kind=="turn")]|length' "${HARNESS_DATA}/events/"*.json)" 2
assert_eq 'duplicate submission' "$(store_submit 'launch tool' main tool-message | jq -r .seq)" 1

# A child reports asynchronously and sees the calling context.
store_submit 'launch child' main child-message >/dev/null
wait_state 'any(.actors[]; .parent=="main" and .status=="completed") and .actors.main.last_reply=="I received the finished work." and .actors.main.request==null and .actors.main.inbox==[]'
assert_eq 'one child report' "$(store_feed | jq '[.events[]|select(.kind=="message" and .data.kind=="work")]|length')" 1
jq -e 'select(.actor!="main") | .payload.messages | any(.[]; .role=="user" and (.content|contains("<parent-context>")) and (.content|contains("launch child")))' "${FIXTURE_REQUEST_LOG}" >/dev/null

# Restart reactor and one HTTP worker while a request is blocked in flight.
store_submit 'gated restart' main restart-message >/dev/null
wait_lines "${FIXTURE_GATE}.started" 1
service_stop web; service_start web
active="$(jq -r '.actors.main.request' "${HARNESS_DATA}/state.json")"
lease="${HARNESS_DATA}/requests/${active}/lease.json"; wait_file "${lease}"
old_pid="$(jq -r '.pid' "${lease}")"
service_stop reactor
process_alive "${old_pid}" "$(jq -r '.start' "${lease}")"
service_start reactor
worker="$(for name in worker-1 worker-2; do
  component_pid="$(jq -r '.pid' "${HARNESS_DATA}/components/${name}.json")"
  child_pid="$(pgrep -P "${component_pid}" | head -1)"
  if pgrep -P "${child_pid}" | rg -qx "${old_pid}"; then printf '%s' "${name}"; break; fi
done)"
[[ -n "${worker}" ]]
service_stop "${worker}"
service_start "${worker}"
wait_lines "${FIXTURE_GATE}.started" 2
assert_file_exists "${HARNESS_DATA}/queue/requests/0-turn/${active}.json"
touch "${FIXTURE_GATE}"
wait_state '.actors.main.last_reply=="Reply: gated restart" and .actors.main.request==null'
assert_eq 'one accepted retry response' "$(curl -fsS "http://127.0.0.1:${HARNESS_SERVE_PORT}/api/events" | jq '[.events[]|select(.kind=="assistant" and .data.text=="Reply: gated restart")]|length')" 1

# More runnable actors than slots cannot exceed the shared HTTP cap.
rm -f "${FIXTURE_GATE}" "${FIXTURE_GATE}.started"
printf '0\n' >"${FIXTURE_COUNTER}.peak"
for actor in cap-a cap-b cap-c; do
  store_emit actor.created "${actor}" "$(jq -cn --arg actor "${actor}" --arg cwd "${HARNESS_CWD}" '{id:$actor,name:$actor,cwd:$cwd,parent:null}')" >/dev/null
  store_submit "gated ${actor}" "${actor}" >/dev/null
done
wait_lines "${FIXTURE_GATE}.started" 2
sleep .3
assert_eq 'third actor stays queued' "$(wc -l <"${FIXTURE_GATE}.started" | tr -d ' ')" 2
assert_eq 'global inference cap' "$(cat "${FIXTURE_COUNTER}.peak")" 2
touch "${FIXTURE_GATE}"
wait_state '[.actors["cap-a"],.actors["cap-b"],.actors["cap-c"]] | all(.[]; .request==null and .inbox==[] and .status=="idle")'
assert_eq 'peak includes all actor and summary calls' "$(cat "${FIXTURE_COUNTER}.peak")" 2

# A stopped tool may already have side effects. Surface uncertainty; never replay.
: >"${FIXTURE_SIDE_EFFECT}"
store_submit 'launch interrupted tool' main interrupted-message >/dev/null
wait_file "${FIXTURE_TOOL_GATE}.started"
job="$(jq -r '.actors.main.pending_jobs[0]' "${HARNESS_DATA}/state.json")"
job_pid="$(jq -r .pid "${HARNESS_DATA}/jobs/${job}/lease.json")"
kill -TERM -- "-${job_pid}"
wait_state '.actors.main.pending_jobs==[] and .actors.main.last_reply=="I received the finished work." and .actors.main.request==null and .actors.main.inbox==[]'
assert_eq 'interrupted tool is not rerun' "$(cat "${FIXTURE_SIDE_EFFECT}")" ran
store_feed | jq -e '.events | any(.[]; .kind=="message" and .data.kind=="echo" and .data.error==true and (.data.text|contains("outcome is unknown")))' >/dev/null

# Cancellation invalidates a queued/active turn and its late completion.
rm -f "${FIXTURE_GATE}" "${FIXTURE_GATE}.started"
store_submit 'gated cancel' main cancel-message >/dev/null
wait_lines "${FIXTURE_GATE}.started" 1
cancelled="$(jq -r '.actors.main.request' "${HARNESS_DATA}/state.json")"
store_cancel main >/dev/null
wait_state '.actors.main.status=="cancelled" and .actors.main.request==null'
store_emit request.completed main "$(jq -cn --arg id "${cancelled}" '{id:$id,response:{blocks:[{type:"text",text:"late cancelled reply"}],stop:"end",usage:{}}}')" late-result >/dev/null
touch "${FIXTURE_GATE}"
store_submit 'after cancel' main after-message >/dev/null
wait_state '.actors.main.last_reply=="Reply: after cancel" and .actors.main.request==null'
assert_eq 'late reply ignored' "$(store_feed | jq '[.events[]|select(.kind=="assistant" and .data.text=="late cancelled reply")]|length')" 0
[[ ! -s "${HARNESS_DATA}/logs/reactor.log" ]]
printf 'asynchronous tool/child flow, worker restart, concurrency cap, interruption and cancellation passed\n'
