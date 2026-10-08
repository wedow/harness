#!/usr/bin/env bash
# Offline regressions for process ownership and durable request completion.
# _tmpdir is assigned by the sourced spec helpers.
# shellcheck disable=SC1091,SC2154
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
HARNESS_ROOT="$(cd "${HARNESS_ROOT}" && pwd)"
export HARNESS_ROOT HARNESS_WORKERS=1 HARNESS_PROVIDER=fixture HARNESS_MODEL=fixture
export FIXTURE_GATE="${_tmpdir}/gate" FIXTURE_COUNTER="${_tmpdir}/counter" FIXTURE_REQUEST_LOG="${_tmpdir}/calls"
export PROCESS_CHILD_FILE="${_tmpdir}/bash-child"
mkdir -p "${HARNESS_HOME}/providers"
cp "${HARNESS_ROOT}/spec/fixtures/provider" "${HARNESS_HOME}/providers/fixture"
source "${HARNESS_ROOT}/lib/bootstrap.sh"
source "${HARNESS_ROOT}/lib/store.sh"
source "${HARNESS_ROOT}/lib/runtime.sh"
store_init

worker_pid=""; running_pid=""
cleanup_processes() {
  local file pid
  for pid in "${worker_pid}" "${running_pid}"; do
    [[ -n "${pid}" ]] || continue
    kill -TERM -- "-${pid}" 2>/dev/null || true
  done
  for file in "${HARNESS_DATA}/requests/"*/lease.json "${HARNESS_DATA}/jobs/"*/lease.json; do
    [[ -f "${file}" ]] || continue
    kill -TERM -- "-$(jq -r '.pid' "${file}")" 2>/dev/null || true
  done
  for file in "${_tmpdir}/bash-child" "${_tmpdir}/job-child"; do
    [[ -f "${file}" ]] || continue
    kill -TERM "$(cat "${file}")" 2>/dev/null || true
  done
  for pid in "${worker_pid}" "${running_pid}"; do
    [[ -n "${pid}" ]] || continue
    kill -KILL -- "-${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  teardown
}
trap cleanup_processes EXIT

wait_for() {
  local label="$1" count
  shift
  for (( count=0; count<500; count++ )); do
    if "$@"; then return 0; fi
    sleep .05
  done
  printf 'FAIL: timed out waiting for %s\n' "${label}" >&2
  return 1
}
file_absent() { [[ ! -f "$1" ]]; }
process_stopped() { ! process_alive "$1"; }
started_count() { [[ -f "${FIXTURE_GATE}.started" ]] && (( $(wc -l <"${FIXTURE_GATE}.started") >= $1 )); }

queue_request() {
  local id="$1" actor="$2" message="$3" record
  record="$(jq -cn --arg id "${id}" --arg actor "${actor}" --arg code "${HARNESS_ROOT}" --arg message "${message}" '{id:$id,actor:$actor,kind:"turn",code_root:$code,provider:"fixture",model:"fixture",tool_bins:{},payload:{model:"fixture",system:"",messages:[{role:"user",content:$message}],tools:[]}}')"
  runtime_queue_request "${record}"
}

# A crash after saving the response but before publishing its completion must
# publish that saved response without making another provider request.
queue_request saved-response main 'must not call the provider'
jq -cn '{id:"saved-response",response:{blocks:[{type:"text",text:"The saved reply."}],stop:"end",usage:{}}}' | atomic_write "${HARNESS_DATA}/requests/saved-response/result.json"
setsid "${HARNESS_ROOT}/lib/worker" 1 >"${_tmpdir}/worker.log" 2>&1 & worker_pid=$!
wait_for 'saved completion' test -f "${HARNESS_DATA}/index/completed-saved-response"
wait_for 'saved queue cleanup' file_absent "${HARNESS_DATA}/queue/requests/0-turn/saved-response.json"
assert_eq 'saved response does not repeat inference' "$(test -f "${FIXTURE_REQUEST_LOG}" && wc -l <"${FIXTURE_REQUEST_LOG}" || printf 0)" 0
assert_eq 'saved response reaches the journal' "$(jq -r '.data.response.blocks[0].text' "${HARNESS_DATA}/events/000000000001.json")" 'The saved reply.'
# Replaying an interrupted queue cleanup must preserve the same event identity.
cat "${HARNESS_DATA}/requests/saved-response/request.json" | atomic_write "${HARNESS_DATA}/queue/requests/0-turn/saved-response.json"
wait_for 'duplicate queue cleanup' file_absent "${HARNESS_DATA}/queue/requests/0-turn/saved-response.json"
assert_eq 'recovery publishes one completion' "$(cat "${HARNESS_DATA}/HEAD")" 1

# Killing only the request leader used to leave its provider alive while the
# worker reused its slot for another actor. The old group must be drained first.
state_update '.actors["actor-b"]=(.actors.main+{id:"actor-b",name:"actor-b"})'
queue_request request-a main 'gated a'
queue_request request-b actor-b 'gated b'
wait_for 'first gated request' started_count 1
first_provider="$(head -1 "${FIXTURE_GATE}.started")"
request_pid="$(jq -r '.pid' "${HARNESS_DATA}/requests/request-a/lease.json")"
kill -KILL "${request_pid}"
wait_for 'request retry after leader death' started_count 2
assert_eq 'leader death preserves the global inference cap' "$(cat "${FIXTURE_COUNTER}.peak")" 1
wait_for 'old provider process removal' process_stopped "${first_provider}"
touch "${FIXTURE_GATE}"
wait_for 'first request completion' test -f "${HARNESS_DATA}/index/completed-request-a"
wait_for 'second request completion' test -f "${HARNESS_DATA}/index/completed-request-b"
assert_eq 'all accepted responses stay within one slot' "$(cat "${FIXTURE_COUNTER}.peak")" 1
assert_eq 'leader retry commits once' "$(jq -sr '[.[]|select(.id=="completed-request-a")]|length' "${HARNESS_DATA}/events/"*.json)" 1
kill -TERM -- "-${worker_pid}"
wait "${worker_pid}" || true
worker_pid=""

# A timed-out bash command must terminate grandchildren as well as the shell.
# The command expands these variables in the child shell.
# shellcheck disable=SC2016
command='sleep 45 & child=$!; printf "%s\n" "$child" > "$PROCESS_CHILD_FILE"; wait "$child"'
jq -cn --arg command "${command}" '{command:$command,timeout:1}' >"${_tmpdir}/bash-input"
setsid "${HARNESS_ROOT}/plugins/core/tools/bash" --exec <"${_tmpdir}/bash-input" >"${_tmpdir}/bash-result" 2>"${_tmpdir}/bash-error" & running_pid=$!
wait_for 'bash child creation' test -f "${PROCESS_CHILD_FILE}"
wait_for 'bash timeout return' process_stopped "${running_pid}"
rc=0; wait "${running_pid}" || rc=$?; running_pid=""
[[ "${rc}" != 0 ]] || { printf 'FAIL: timed-out bash command succeeded\n' >&2; exit 1; }
assert_json '.timed_out' "$(cat "${_tmpdir}/bash-result")" true
wait_for 'bash timeout descendant cleanup' process_stopped "$(cat "${PROCESS_CHILD_FILE}")"

# The outer job timeout also owns descendants of arbitrary plugin tools.
export PROCESS_CHILD_FILE="${_tmpdir}/job-child" HARNESS_TOOL_TIMEOUT=1
cat >"${_tmpdir}/fixture-tool" <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
sleep 45 & child=$!
printf '%s\n' "${child}" >"${PROCESS_CHILD_FILE}"
wait "${child}"
TOOL
chmod +x "${_tmpdir}/fixture-tool"
mkdir -p "${HARNESS_DATA}/jobs/timeout-job"
jq -cn --arg binary "${_tmpdir}/fixture-tool" --arg cwd "${HARNESS_CWD}" '{id:"timeout-job",actor:"main",name:"fixture-tool",input:{},binary:$binary,cwd:$cwd,kind:"tool"}' | atomic_write "${HARNESS_DATA}/jobs/timeout-job/job.json"
cat "${HARNESS_DATA}/jobs/timeout-job/job.json" | atomic_write "${HARNESS_DATA}/queue/jobs/timeout-job.json"
setsid "${HARNESS_ROOT}/lib/job" timeout-job >"${_tmpdir}/job-log" 2>&1 & running_pid=$!
wait_for 'plugin tool child creation' test -f "${PROCESS_CHILD_FILE}"
wait_for 'plugin job timeout return' process_stopped "${running_pid}"
wait "${running_pid}" || true; running_pid=""
assert_json '.error' "$(cat "${HARNESS_DATA}/jobs/timeout-job/result.json")" true
wait_for 'plugin timeout descendant cleanup' process_stopped "$(cat "${PROCESS_CHILD_FILE}")"
assert_eq 'job completion is committed once' "$(jq -sr '[.[]|select(.id=="completed-timeout-job")]|length' "${HARNESS_DATA}/events/"*.json)" 1

printf 'PASS: saved-response recovery, request leader crash cap, and timeout descendant cleanup\n'
