#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
HARNESS_ROOT="$(cd "${HARNESS_ROOT}" && pwd)"
export HARNESS_ROOT
# setup in helpers.sh supplies _tmpdir.
# shellcheck disable=SC2154
export HARNESS_HOME="${_tmpdir}/home" HARNESS_DATA="${_tmpdir}/store" HARNESS_CWD="${PWD}"
source "${HARNESS_ROOT}/lib/bootstrap.sh"
source "${HARNESS_ROOT}/lib/store.sh"

check() { [[ "$1" == "$2" ]] || { printf 'FAIL: %s\nexpected: %s\nactual: %s\n' "$3" "$2" "$1" >&2; exit 1; }; }
reject() { if "$@" >/dev/null 2>&1; then echo "FAIL: unexpectedly accepted $*" >&2; exit 1; fi; }
reset_store() { HARNESS_DATA="${_tmpdir}/$1"; export HARNESS_DATA; store_init; }
publish_interrupted() {
  local seq="$1" id="$2" text="$3"
  jq -cn --argjson seq "${seq}" --arg id "${id}" --arg text "${text}" \
    '{seq:$seq,id:$id,actor:"main",kind:"message",data:{kind:"user",text:$text},date:"2026-10-08T00:00:00Z"}' \
    | atomic_write "${HARNESS_DATA}/events/$(printf '%012d' "${seq}").json"
}

store_init
# A failed or killed JSON producer must not replace a valid projection with
# an empty/partial document, even when the consuming cat reaches ordinary EOF.
projection="$(cat "${HARNESS_DATA}/state.json")"
if printf '{"cursor":' | atomic_write "${HARNESS_DATA}/state.json" 2>/dev/null; then
  echo 'FAIL: partial JSON was published' >&2; exit 1
fi
check "$(cat "${HARNESS_DATA}/state.json")" "${projection}" 'partial producer preserves previous projection'
if printf '' | atomic_write "${HARNESS_DATA}/state.json" 2>/dev/null; then
  echo 'FAIL: empty JSON was published' >&2; exit 1
fi
check "$(cat "${HARNESS_DATA}/state.json")" "${projection}" 'empty producer preserves previous projection'
first="$(store_submit 'exact user text é😀' main stable-message)"
before="$(sha256sum "${HARNESS_DATA}/events/000000000001.json")"
check "$(store_submit 'exact user text é😀' main stable-message)" "${first}" 'same stable ID and content returns same acknowledgement'
check "$(sha256sum "${HARNESS_DATA}/events/000000000001.json")" "${before}" 'dedupe preserves committed event bytes'
reject store_submit 'changed contents' main stable-message
reject store_emit message ../actor '{"text":"bad"}' invalid-actor
check "$(cat "${HARNESS_DATA}/HEAD")" 1 'rejected submissions do not allocate sequences'

# External command arguments must not carry a large message or dedupe payload.
large="$(jq -nr '"x"*300000')"
ack="$(store_submit "${large}" main large-message)"
check "$(printf '%s' "${ack}" | jq -r '.seq')" 2 'large message publishes'
check "$(jq '.data.text|length' "${HARNESS_DATA}/events/000000000002.json")" 300000 'large message retained in full'
check "$(store_submit "${large}" main large-message)" "${ack}" 'large dedupe avoids ARG_MAX'

# Concurrent appenders receive unique dense ordered sequences under the lock.
pids=()
for i in {1..24}; do
  store_submit "parallel ${i}" main "parallel-${i}" > "${_tmpdir}/ack-${i}" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "${pid}"; done
check "$(cat "${HARNESS_DATA}/HEAD")" 26 'concurrent sequence allocation'
check "$(jq -sr '[.[].seq]|sort == [range(1;27)]' "${HARNESS_DATA}/events/"*.json)" true 'event sequence is dense and numeric'
check "$(jq -sr '[.[].id]|unique|length' "${HARNESS_DATA}/events/"*.json)" 26 'stable IDs remain unique'
check "$(jq -sr '[.[].seq]|unique|length' "${_tmpdir}/ack-"*)" 24 'every concurrent client receives its own sequence'

# Legacy raw stable IDs may have reserved a future generated name and suffix.
# Automatic publication must preserve those records and their original retries.
reset_store auto-id-collision
reserved="$(store_emit message main '{"kind":"user","text":"reserved generated name"}' event-3 | jq -c '{id,seq}')"
reserved_suffix="$(store_emit message main '{"kind":"user","text":"reserved first suffix"}' event-3-1 | jq -c '{id,seq}')"
generated="$(store_submit 'automatically identified message' main)"
check "$(printf '%s' "${generated}" | jq '.seq')" 3 'collision resolution preserves sequence allocation'
check "$(jq -s '[.[].id]|unique|length' "${HARNESS_DATA}/events/"*.json)" 3 'generated event IDs stay unique when candidates are reserved'
check "$(store_submit 'reserved generated name' main event-3)" "${reserved}" 'automatic ID preserves supplied stable acknowledgement'
check "$(store_submit 'reserved first suffix' main event-3-1)" "${reserved_suffix}" 'automatic ID preserves reserved suffix acknowledgement'
check "$(cat "${HARNESS_DATA}/HEAD")" 3 'retrying reserved IDs does not duplicate messages'
check "$(store_submit 'ordinary generated message' main | jq -r '.id')" event-4 'unreserved automatic IDs keep their ordinary name'

# Client identities are scoped by actor, distinct from all runtime identifiers,
# and take precedence over an unrelated generated event with the same raw name.
reset_store client-namespace
client_ack="$(store_submit 'named input' main event-2)"
client_event="$(cat "${HARNESS_DATA}/events/000000000001.json")"
check "$(printf '%s' "${client_event}" | jq -r '.data.message_id')" event-2 'original client identity is retained for browser reconciliation'
check "$(printf '%s' "${client_ack}" | jq -r '.id')" event-2 'acknowledgement retains the supplied identity'
store_submit 'automatically identified input' main >/dev/null
check "$(store_submit 'named input' main event-2)" "${client_ack}" 'namespaced retry wins over a later raw generated identity'
reject store_submit 'changed named input' main event-2
other_ack="$(store_submit 'another actor input' child-one event-2)"
check "$(store_submit 'another actor input' child-one event-2)" "${other_ack}" 'client identity is scoped by actor'
check "$(jq -s '[.[].id]|unique|length' "${HARNESS_DATA}/events/"*.json)" 3 'actor-scoped client identities are unique'
reserved_id="$(printf '%s' "${client_event}" | jq -r '.id')"
reject store_submit 'physical journal identity' main "${reserved_id}"
reject store_emit assistant main '{"text":"cannot reserve a client identity"}' "client-$(printf '%064d' 0)"
check "$(cat "${HARNESS_DATA}/HEAD")" 3 'reserved and changed identities do not publish another event'

# Retry lookup and publication share the journal lock, including concurrent
# callers which all arrive before the first acknowledgement is delivered.
reset_store concurrent-client-retry
pids=()
for i in {1..8}; do
  store_submit 'same pending message' main shared-client-id > "${_tmpdir}/shared-ack-${i}" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "${pid}"; done
check "$(cat "${HARNESS_DATA}/HEAD")" 1 'concurrent same-ID retries publish once'
check "$(jq -s 'unique|length' "${_tmpdir}/shared-ack-"*)" 1 'concurrent same-ID retries receive the same acknowledgement'

# Preclaiming deterministic runtime names as client names cannot wedge a turn.
export HARNESS_CWD="${_tmpdir}"
reset_store runtime-id-claims
source "${HARNESS_ROOT}/lib/memory.sh"
source "${HARNESS_ROOT}/lib/runtime.sh"
request_id=request-main-0-1
job_id="job-$(stable_id "${request_id}:1")"
for claimed in "queued-${request_id}" "assistant-${request_id}" "error-${request_id}" "tool-${job_id}" "queued-${job_id}" "completed-${request_id}" "completed-${job_id}" "observation-${job_id}" "queued-summary-main-0-0-0" "cancel-${job_id}"; do
  ack="$(store_submit "claim ${claimed}" main "${claimed}")"
  seq="$(printf '%s' "${ack}" | jq -r '.seq')"
  event="$(cat "${HARNESS_DATA}/events/$(printf '%012d' "${seq}").json")"
  check "$(printf '%s' "${event}" | jq -r '.id==.data.message_id')" false 'client name cannot claim an internal journal identity'
  runtime_apply_event "${event}"
done
mkdir -p "${HARNESS_HOME}/providers"
cat > "${HARNESS_HOME}/providers/namespace-fixture" <<'PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in --defaults) printf 'model=fixture\n' ;; *) echo 'unexpected inference' >&2; exit 1 ;; esac
PROVIDER
chmod +x "${HARNESS_HOME}/providers/namespace-fixture"
export HARNESS_PROVIDER=namespace-fixture HARNESS_MODEL=fixture
runtime_schedule_actor main
queued="$(jq -sc '[.[]|select(.kind=="request.queued")]|last' "${HARNESS_DATA}/events/"*.json)"
runtime_apply_event "${queued}"
check "$(state_actor main | jq -r '.request')" "${request_id}" 'a turn schedules despite claimed internal names'
completion="$(store_emit request.completed main "$(jq -cn --arg id "${request_id}" '{id:$id,response:{blocks:[{type:"text",text:"Finished safely"},{type:"tool_call",id:"call-1",name:"bash",input:{command:"printf safe"}}],stop:"tool_calls",usage:{}}}')" "completed-${request_id}")"
runtime_apply_event "${completion}"
derived="$(jq -sc '[.[]|select(.kind=="job.queued")]|last' "${HARNESS_DATA}/events/"*.json)"
runtime_apply_event "${derived}"
check "$(jq '.jobs|length' "${HARNESS_DATA}/state.json")" 1 'derived tool publication is not wedged'
check "$(jq -s '[.[].id]|length == (unique|length)' "${HARNESS_DATA}/events/"*.json)" true 'runtime and client event identities remain unique'

# Crash before index publication: retry discovers the committed event and
# finishes index/HEAD instead of committing another message.
reset_store recovery-event
publish_interrupted 1 recover-event 'saved before index'
check "$(store_submit 'saved before index' main recover-event | jq -r '.seq')" 1 'event-only interrupted commit dedupes'
check "$(cat "${HARNESS_DATA}/HEAD")" 1 'event-only recovery advances HEAD'
check "$(cat "${HARNESS_DATA}/index/recover-event")" 1 'event-only recovery restores index'

# Crash after event/index publication but before HEAD: the same-ID fast path
# must also finish recovery so acknowledgement and feed visibility agree.
reset_store recovery-index
publish_interrupted 1 recover-index 'saved before HEAD'
printf '1\n' | atomic_write "${HARNESS_DATA}/index/recover-index"
check "$(store_submit 'saved before HEAD' main recover-index | jq -r '.seq')" 1 'event/index interrupted commit dedupes'
check "$(cat "${HARNESS_DATA}/HEAD")" 1 'indexed retry recovers stale HEAD'
check "$(store_feed 0 0 10 | jq '.events|length')" 1 'acknowledged recovered event is visible'

# A namespaced record published before its index/HEAD is repaired before lookup.
reset_store recovery-client
identity="client-$(printf '%s' main:recover-client | sha256sum | cut -d' ' -f1)"
jq -cn --arg id "${identity}" '{seq:1,id:$id,actor:"main",kind:"message",data:{kind:"user",text:"saved client input",message_id:"recover-client"},date:"2026-10-08T00:00:00Z"}' \
  | atomic_write "${HARNESS_DATA}/events/000000000001.json"
check "$(store_submit 'saved client input' main recover-client | jq -c '[.id,.seq]')" '["recover-client",1]' 'interrupted namespaced retry retains its client acknowledgement'
check "$(cat "${HARNESS_DATA}/HEAD")" 1 'namespaced recovery does not duplicate input'

# Recovery also precedes allocating an unrelated append, preserving order.
reset_store recovery-next
publish_interrupted 1 older 'committed earlier'
check "$(store_submit 'new request' main newer | jq -r '.seq')" 2 'new append follows recovered event'
check "$(cat "${HARNESS_DATA}/index/older")" 1 'unrelated append recovers earlier index'

# Replay of a message after projection publication but before cursor update
# must neither duplicate its inbox item nor its permanent memory record.
reset_store projection
source "${HARNESS_ROOT}/lib/memory.sh"
source "${HARNESS_ROOT}/lib/runtime.sh"
event="$(store_emit message main '{"kind":"user","text":"once in inbox"}' once)"
runtime_apply_event "${event}"
state_update '.cursor=0'
runtime_apply_event "${event}"
check "$(jq -c '.actors.main.inbox' "${HARNESS_DATA}/state.json")" '[1]' 'interrupted projection replay preserves unique inbox'
check "$(jq '.total' "${HARNESS_DATA}/actors/main/memory/state.json")" 1 'projection replay preserves permanent memory ID'

# Feeds skip internal and child events, sort selected events oldest first,
# and keep a global cursor even when the skipped events form the final tail.
reset_store feed
store_emit message main '{"kind":"user","text":"one"}' one >/dev/null
store_emit request.queued main '{"id":"r1"}' internal-one >/dev/null
store_emit message child-one '{"kind":"user","text":"child task"}' child-task >/dev/null
store_emit assistant main '{"text":"two"}' two >/dev/null
store_emit tool main '{"name":"bash","input":{},"call_id":"c1"}' three >/dev/null
store_emit message main '{"kind":"echo","text":"four"}' four >/dev/null
store_emit job.completed main '{"id":"j1","result":"internal"}' internal-tail >/dev/null
feed="$(store_feed 0 0 2)"
check "$(printf '%s' "${feed}" | jq -c '[.events[].seq]')" '[5,6]' 'initial feed gets most recent visible page'
check "$(printf '%s' "${feed}" | jq -r '.cursor')" 7 'initial feed cursor includes internal tail'
check "$(printf '%s' "${feed}" | jq -r '.has_more')" true 'history has earlier pages'
check "$(store_feed 0 5 2 | jq -c '[.events[].seq]')" '[1,4]' 'history page skips internal and child events'
feed="$(store_feed 1 0 2)"
check "$(printf '%s' "${feed}" | jq -c '[.events[].seq]')" '[4,5]' 'incremental feed skips bookkeeping'
check "$(printf '%s' "${feed}" | jq -r '.cursor')" 5 'bounded incremental cursor resumes after its last event'
feed="$(store_feed 5 0 2)"
check "$(printf '%s' "${feed}" | jq -c '[.events[].seq]')" '[6]' 'incremental final page'
check "$(printf '%s' "${feed}" | jq -r '.cursor')" 7 'incremental cursor passes skipped trailing events'
check "$(printf '%s' "${feed}" | jq -r '.has_more')" false 'final feed page exhausted'
reject store_feed bad 0 10
reject store_feed 0 0 201

echo PASS
