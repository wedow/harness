#!/usr/bin/env bash
# Replay publication races deterministically; no services or network calls.
# shellcheck disable=SC1091,SC2154
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
HARNESS_ROOT="$(cd "${HARNESS_ROOT}" && pwd)"
export HARNESS_ROOT HARNESS_LIVE_ROOT="${HARNESS_ROOT}"
export HARNESS_HOME="${_tmpdir}/config" HARNESS_CWD="${_tmpdir}/actor-a"
export HARNESS_PROVIDER=fixture-alpha HARNESS_MODEL=''
mkdir -p "${HARNESS_HOME}/providers" "${HARNESS_CWD}/.harness" "${_tmpdir}/actor-b/.harness"
for provider in alpha beta summary; do
  cat > "${HARNESS_HOME}/providers/fixture-${provider}" <<'PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --describe) printf 'deterministic fixture provider\n' ;;
  --ready) exit 0 ;;
  --defaults) printf 'model=%s-default\n' "${0##*fixture-}" ;;
  --env) exit 0 ;;
  *) echo 'unexpected inference in scheduler-only test' >&2; exit 1 ;;
esac
PROVIDER
  chmod +x "${HARNESS_HOME}/providers/fixture-${provider}"
done
printf 'provider=fixture-alpha\nmodel=alpha-selected\n' > "${_tmpdir}/actor-a/.harness/settings.conf"
printf 'provider=fixture-beta\nmodel=beta-selected\n' > "${_tmpdir}/actor-b/.harness/settings.conf"
source "${HARNESS_ROOT}/lib/bootstrap.sh"
source "${HARNESS_ROOT}/lib/store.sh"
source "${HARNESS_ROOT}/lib/memory.sh"
source "${HARNESS_ROOT}/lib/runtime.sh"

reset_store() {
  HARNESS_DATA="${_tmpdir}/$1"; HARNESS_CWD="${_tmpdir}/actor-a"
  HARNESS_PROVIDER=fixture-alpha; HARNESS_MODEL=''
  export HARNESS_DATA HARNESS_CWD HARNESS_PROVIDER HARNESS_MODEL
  unset HARNESS_SUMMARY_PROVIDER HARNESS_SUMMARY_MODEL
  store_init
}
apply() {
  local event
  event="$(store_emit "$@")"
  runtime_apply_event "${event}"
}
latest_request() {
  jq -sc '[.[]|select(.kind=="request.queued" and .actor==$actor and .data.kind==$kind)]|last' \
    --arg actor "${1:-main}" --arg kind "${2:-turn}" "${HARNESS_DATA}/events/"*.json
}
schedule_turn() {
  # Production captures these baselines once per tick, before visiting actors.
  local _runtime_provider="${HARNESS_PROVIDER}" _runtime_model="${HARNESS_MODEL}"
  runtime_schedule_actor "$1"
}
start_turn() {
  apply message main '{"kind":"user","text":"original task"}' original-input
  schedule_turn main
  runtime_apply_event "$(latest_request)"
}
assert_state() {
  jq -e "$1" "${HARNESS_DATA}/state.json" >/dev/null || {
    printf 'FAIL: %s\n' "$2" >&2
    cat "${HARNESS_DATA}/state.json" >&2
    return 1
  }
}
assert_no_jobs() {
  assert_state '(.jobs|length)==0 and .actors.main.pending_jobs==[]' "$1"
  assert_eq "$1: no executable job is queued" "$(find "${HARNESS_DATA}/queue/jobs" -type f | wc -l | tr -d ' ')" 0
}

# A launch ends the turn. Calling the model merely to narrate a receipt can
# produce a stale "still running" reply after a fast tool has already finished.
reset_store tool-turn
start_turn
request="$(state_actor main | jq -r '.request')"
apply request.completed main "$(jq -cn --arg id "${request}" \
  '{id:$id,response:{blocks:[{type:"tool_call",id:"fast-call",name:"bash",input:{command:"printf fast"}}],stop:"tool_calls",usage:{}}}')" completed-tool-turn
while IFS= read -r event; do runtime_apply_event "${event}"; done < <(
  jq -c 'select(.kind=="tool" or .kind=="job.queued")' "${HARNESS_DATA}/events/"*.json
)
assert_state '.actors.main.request==null and .actors.main.followup==false and (.actors.main.pending_jobs|length)==1' 'a launched tool waits for actual input, not receipt narration'
schedule_turn main
assert_eq 'no inference is scheduled just to acknowledge launch' "$(jq -s '[.[]|select(.kind=="request.queued")]|length' "${HARNESS_DATA}/events/"*.json)" 1
job="$(state_actor main | jq -r '.pending_jobs[0]')"
apply job.completed main "$(jq -cn --arg id "${job}" '{id:$id,result:"fast result",error:false}')" completed-fast-job
observation="$(jq -sc '[.[]|select(.kind=="message" and .data.kind=="echo")]|last' "${HARNESS_DATA}/events/"*.json)"
runtime_apply_event "${observation}"
schedule_turn main
next_request="$(latest_request)"
printf '%s' "${next_request}" | jq -e '.data.payload.messages[-1].content | contains("fast result")' >/dev/null
assert_eq 'completion starts a fresh turn' "$(printf '%s' "${next_request}" | jq -r '.data.turn')" "$(printf '%s' "${observation}" | jq -r '.seq')"
assert_eq 'only the launch and result calls are needed' "$(jq -s '[.[]|select(.kind=="request.queued")]|length' "${HARNESS_DATA}/events/"*.json)" 2

# Truncation still resumes the exact response instead of waiting for input.
reset_store length-turn
start_turn
request="$(state_actor main | jq -r '.request')"
apply request.completed main "$(jq -cn --arg id "${request}" \
  '{id:$id,response:{blocks:[{type:"text",text:"Partial answer"}],stop:"length",usage:{}}}')" completed-length-turn
schedule_turn main
printf '%s' "$(latest_request)" | jq -e '.data.payload.messages[-1].content=="Continue the truncated response from where it ended. Do not repeat completed work."' >/dev/null
assert_eq 'an output limit still queues a continuation' "$(jq -s '[.[]|select(.kind=="request.queued")]|length' "${HARNESS_DATA}/events/"*.json)" 2

# Steering can be committed before the active call publishes its reply and
# tools. The next fresh turn must see that interleaved history as well as input.
reset_store in-flight-input
start_turn
request="$(state_actor main | jq -r '.request')"
apply message main '{"kind":"user","text":"steering during the call"}' in-flight-steering
apply request.completed main "$(jq -cn --arg id "${request}" \
  '{id:$id,response:{blocks:[{type:"text",text:"Completed earlier reply"},{type:"tool_call",id:"interleaved-call",name:"bash",input:{command:"printf pending"}}],stop:"tool_calls",usage:{}}}')" completed-in-flight
while IFS= read -r event; do runtime_apply_event "${event}"; done < <(
  jq -c 'select(.kind=="assistant" or .kind=="tool" or .kind=="job.queued")' "${HARNESS_DATA}/events/"*.json
)
schedule_turn main
next_request="$(latest_request)"
printf '%s' "${next_request}" | jq -e '
  .data.payload.messages as $messages |
  ([$messages[] | select(.role=="user" and .content=="steering during the call")]|length)==1 and
  any($messages[]; (.content // "" | contains("Completed earlier reply"))) and
  any($messages[]; (.content // "" | contains("interleaved-call"))) and
  all($messages[]; .role=="user")' >/dev/null

# A completion publishes derived events after cancellation was already committed.
# New user input can make the actor ready before the old job event is projected.
for scenario in cancelled fresh-input; do
  reset_store "derived-${scenario}"
  start_turn
  request="$(state_actor main | jq -r '.request')"
  tool=bash; input='{"command":"printf should-not-run"}'
  if [[ "${scenario}" == fresh-input ]]; then
    tool=agent; input='{"name":"stale-child","prompt":"should not spawn"}'
  fi
  completion="$(store_emit request.completed main "$(jq -cn --arg id "${request}" --arg name "${tool}" --argjson input "${input}" \
    '{id:$id,response:{blocks:[{type:"tool_call",id:"call-1",name:$name,input:$input}],stop:"tool_calls",usage:{}}}')" completed-original)"
  cancellation="$(store_emit cancel main '{}' cancel-original)"
  fresh=''
  if [[ "${scenario}" == fresh-input ]]; then
    fresh="$(store_emit message main '{"kind":"user","text":"new task"}' fresh-input)"
  fi
  runtime_apply_event "${completion}"
  derived="$(jq -sc '[.[]|select(.kind=="job.queued")]|last' "${HARNESS_DATA}/events/"*.json)"
  [[ "${derived}" != null ]]
  runtime_apply_event "${cancellation}"
  [[ -z "${fresh}" ]] || runtime_apply_event "${fresh}"
  runtime_apply_event "${derived}"
  assert_no_jobs "${scenario}: an old derived job cannot revive cancelled work"
  assert_state '(.actors.main.epoch // 0)==1' 'cancel advances the actor generation'
  if [[ "${scenario}" == fresh-input ]]; then
    fresh_seq="$(printf '%s' "${fresh}" | jq -r '.seq')"
    assert_eq 'fresh input remains ready' "$(state_actor main | jq -r '.status')" ready
    assert_eq 'only the fresh message wakes the new turn' "$(state_actor main | jq -c '.inbox')" "[${fresh_seq}]"
    assert_eq 'stale delegation creates no child actor event' "$(jq -s '[.[]|select(.kind=="actor.created")]|length' "${HARNESS_DATA}/events/"*.json)" 0
  else
    assert_state '.actors.main.status=="cancelled" and .actors.main.inbox==[]' 'cancelled actor stays stopped'
  fi
done

# A crash after cancellation state was saved but before cursor publication
# must not apply the same cancellation twice.
reset_store cancel-replay
cancellation="$(store_emit cancel main '{}' repeat-cancel)"
runtime_apply_event "${cancellation}"
state_update '.cursor=0'
runtime_apply_event "${cancellation}"
assert_state '.actors.main.epoch==1' 'cancel replay preserves the generation'

# Scheduling can finish while a cancellation is waiting in the journal. The
# resulting old-generation turn event must not replace a newer ready task.
reset_store delayed-turn
apply message main '{"kind":"user","text":"original queued task"}' queued-input
cancellation="$(store_emit cancel main '{}' cancel-queued-turn)"
fresh="$(store_emit message main '{"kind":"user","text":"replacement task"}' replacement-input)"
schedule_turn main
delayed_request="$(latest_request)"
[[ "${delayed_request}" != null ]]
runtime_apply_event "${cancellation}"
runtime_apply_event "${fresh}"
runtime_apply_event "${delayed_request}"
assert_state '.actors.main.request==null and .actors.main.status=="ready" and (.requests|length)==0' 'old queued turn cannot replace the fresh task'
assert_eq 'old turn never reaches an inference queue' "$(find "${HARNESS_DATA}/queue/requests" -type f | wc -l | tr -d ' ')" 0
fresh_seq="$(printf '%s' "${fresh}" | jq -r '.seq')"
assert_eq 'replacement task remains in the inbox' "$(state_actor main | jq -c '.inbox')" "[${fresh_seq}]"
schedule_turn main
replacement_request="$(latest_request)"
assert_json '.data.epoch' "${replacement_request}" 1
printf '%s\n%s' "${delayed_request}" "${replacement_request}" | jq -es '.[0].data.id!=.[1].data.id' >/dev/null
runtime_apply_event "${replacement_request}"
assert_state '.actors.main.request!=null and .actors.main.status=="running" and (.requests|length)==1' 'replacement is scheduled after rejecting the cancelled queue event'

# Job completion can derive an echo after cancel/new input were committed.
# The durable result remains in memory, while its old observation cannot wake a
# later generation of the actor.
reset_store delayed-observation
job="$(jq -cn --arg root "${HARNESS_ROOT}" --arg cwd "${HARNESS_CWD}" \
  '{id:"old-job",actor:"main",epoch:0,kind:"tool",name:"bash",input:{},call_id:"old-call",binary:"",code_root:$root,cwd:$cwd}')"
apply job.queued main "${job}" queued-old-job
completion="$(store_emit job.completed main '{"id":"old-job","result":"stale result","error":false}' completed-old-job)"
cancellation="$(store_emit cancel main '{}' cancel-old-job)"
fresh="$(store_emit message main '{"kind":"user","text":"new task after tool"}' fresh-after-tool)"
runtime_apply_event "${completion}"
observation="$(jq -sc '[.[]|select(.kind=="message" and .data.kind=="echo")]|last' "${HARNESS_DATA}/events/"*.json)"
[[ "${observation}" != null ]]
runtime_apply_event "${cancellation}"
runtime_apply_event "${fresh}"
runtime_apply_event "${observation}"
assert_no_jobs 'completion before cancel cannot leave executable old work'
fresh_seq="$(printf '%s' "${fresh}" | jq -r '.seq')"
assert_eq 'old result does not enter the new inbox' "$(state_actor main | jq -c '.inbox')" "[${fresh_seq}]"
assert_eq 'the permanent log retains both committed messages' "$(jq '.total' "${HARNESS_DATA}/actors/main/memory/state.json")" 2

# Actor-local settings must be selected independently in the same tick, even
# after scheduling the first actor mutates the process environment.
reset_store actor-config
apply actor.created actor-b "$(jq -cn --arg cwd "${_tmpdir}/actor-b" '{id:"actor-b",name:"actor-b",cwd:$cwd,parent:null}')" actor-b
apply message main '{"kind":"user","text":"alpha task"}' alpha-task
apply message actor-b '{"kind":"user","text":"beta task"}' beta-task
schedule_config_pair() {
  local _runtime_provider='' _runtime_model=''
  runtime_schedule_actor main
  runtime_schedule_actor actor-b
}
HARNESS_PROVIDER=''; HARNESS_MODEL=''
schedule_config_pair
assert_json '.data.provider' "$(latest_request main)" fixture-alpha
assert_json '.data.model' "$(latest_request main)" alpha-selected
assert_json '.data.provider' "$(latest_request actor-b)" fixture-beta
assert_json '.data.model' "$(latest_request actor-b)" beta-selected

# A different summary provider chooses its own default model rather than
# inheriting an incompatible model from the turn provider or previous actor.
reset_store summary-config
long_text="$(jq -nr '"long message "*100')"
apply message main "$(printf '%s' "${long_text}" | jq -Rs '{kind:"user",text:.}')" long-message
export HARNESS_SUMMARY_PROVIDER=fixture-summary
schedule_summary() {
  local _runtime_provider='' _runtime_model=''
  runtime_schedule_summaries main
}
schedule_summary
assert_json '.data.provider' "$(latest_request main summary)" fixture-summary
assert_json '.data.model' "$(latest_request main summary)" summary-default
assert_json '.data.payload.model' "$(latest_request main summary)" summary-default

# A hot edit between copy and publication must retry instead of storing a mixed
# version under the digest calculated before the edit. Already queued code stays
# frozen, and the retried snapshot executes the newer deterministic provider.
reset_store code-versions
HARNESS_LIVE_ROOT="${_tmpdir}/live-code"; export HARNESS_LIVE_ROOT
mkdir -p "${HARNESS_LIVE_ROOT}/bin" "${HARNESS_LIVE_ROOT}/lib" "${HARNESS_LIVE_ROOT}/plugins/fixture/providers"
printf '#!/usr/bin/env bash\nexit 0\n' > "${HARNESS_LIVE_ROOT}/bin/harness"
printf 'version=first\n' > "${HARNESS_LIVE_ROOT}/lib/version.sh"
write_provider() {
  cat > "${HARNESS_LIVE_ROOT}/plugins/fixture/providers/fixture-snapshot" <<PROVIDER
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf '%s\n' '{"blocks":[{"type":"text","text":"$1"}],"stop":"end","usage":{}}'
PROVIDER
  chmod +x "${HARNESS_LIVE_ROOT}/plugins/fixture/providers/fixture-snapshot"
}
write_provider first
first_code="$(code_snapshot)"
assert_eq 'snapshot digest describes its actual content and modes' "${first_code##*/}" "$(code_digest "${first_code}")"
assert_eq 'unchanged code reuses its immutable snapshot' "$(code_snapshot)" "${first_code}"
printf 'version=second\n' > "${HARNESS_LIVE_ROOT}/lib/version.sh"
write_provider second
copy_marker="${_tmpdir}/snapshot-copy-edited"
snapshot_during_edit() (
  cp() {
    command cp "$@"
    if [[ ! -f "${copy_marker}" ]]; then
      printf 'version=third\n' > "${HARNESS_LIVE_ROOT}/lib/version.sh"
      write_provider third
      touch "${copy_marker}"
    fi
  }
  code_snapshot
)
next_code="$(snapshot_during_edit)"
[[ -f "${copy_marker}" && "${first_code}" != "${next_code}" ]]
assert_eq 'edit during copy yields a coherent retried snapshot' "$(cat "${next_code}/lib/version.sh")" version=third
assert_eq 'published digest matches the retried copy' "${next_code##*/}" "$(code_digest "${next_code}")"
assert_eq 'earlier requests retain their original code' "$(cat "${first_code}/lib/version.sh")" version=first
assert_eq 'earlier provider remains pinned' "$(printf '{}' | "${first_code}/plugins/fixture/providers/fixture-snapshot" | jq -r '.blocks[0].text')" first
assert_eq 'new work can use the updated provider' "$(printf '{}' | "${next_code}/plugins/fixture/providers/fixture-snapshot" | jq -r '.blocks[0].text')" third

printf 'PASS: asynchronous turn boundaries, cancellation generations, delayed observations, configuration, and hot snapshots\n'
