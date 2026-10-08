#!/usr/bin/env bash
# Immutable events are authoritative; state and queues are replayable projections.
set -euo pipefail

store_init() (
  umask 077
  mkdir -p "${HARNESS_HOME}" "${HARNESS_DATA}"/{events,index,locks,components,logs,actors,code,queue/requests/0-turn,queue/requests/1-summary,queue/jobs,requests,jobs}
  exec 7>"${HARNESS_DATA}/locks/journal"
  flock 7
  if [[ ! -f "${HARNESS_DATA}/HEAD" ]]; then printf '0\n' | atomic_write "${HARNESS_DATA}/HEAD"; fi
  _store_recover_locked || return
  if [[ ! -f "${HARNESS_DATA}/state.json" ]]; then
    jq -cn --arg cwd "${HARNESS_CWD}" '{cursor:0,actors:{main:{id:"main",name:"main",parent:null,cwd:$cwd,inbox:[],ledger:[],request:null,turn:null,pending_jobs:[],status:"idle"}},requests:{},jobs:{}}' | atomic_write "${HARNESS_DATA}/state.json"
  fi
)

_store_recover_locked() {
  local seq file identity
  seq="$(cat "${HARNESS_DATA}/HEAD")" || return
  while file="${HARNESS_DATA}/events/$(printf '%012d' "$((seq+1))").json"; [[ -f "${file}" ]]; do
    seq=$((seq+1)); identity="$(jq -r '.id' "${file}")" || return
    printf '%s\n' "${seq}" | atomic_write "${HARNESS_DATA}/index/${identity}" || return
  done
  printf '%s\n' "${seq}" | atomic_write "${HARNESS_DATA}/HEAD"
}

_store_client_identity() { [[ "$1" =~ ^client-[a-f0-9]{64}$ ]]; }

store_emit() (
  local kind="$1" actor="$2" data="$3" identity="${4:-}"
  valid_id "${actor}" || return 1
  [[ -z "${identity}" ]] || valid_id "${identity}" || return 1
  printf '%s' "${data}" | jq -e 'type == "object"' >/dev/null || return 1
  exec 7>"${HARNESS_DATA}/locks/journal"; flock 7
  _store_recover_locked || return
  _store_publish_locked "${kind}" "${actor}" "${data}" "${identity}"
)

# Caller holds the journal lock and has recovered its published tail.
_store_publish_locked() {
  local kind="$1" actor="$2" data="$3" identity="$4" scope="${5:-internal}" seq file existing suffix=0
  seq="$(cat "${HARNESS_DATA}/HEAD")" || return
  if [[ -n "${identity}" && -f "${HARNESS_DATA}/index/${identity}" ]]; then
    existing="$(cat "${HARNESS_DATA}/index/${identity}")"
    file="${HARNESS_DATA}/events/$(printf '%012d' "${existing}").json"
    printf '%s' "${data}" | jq -e --arg k "${kind}" --arg a "${actor}" --slurpfile event "${file}" '. as $d | $event[0] | .kind==$k and .actor==$a and .data==$d' >/dev/null || { printf 'event ID already used with different content\n' >&2; return 65; }
    cat "${file}"; return
  fi
  if [[ "${scope}" != client ]] && _store_client_identity "${identity}"; then
    printf 'client journal IDs are reserved for message submissions\n' >&2; return 64
  fi
  seq=$((seq+1))
  if [[ -z "${identity}" ]]; then
    identity="event-${seq}"
    while [[ -f "${HARNESS_DATA}/index/${identity}" ]]; do
      suffix=$((suffix+1)); identity="event-${seq}-${suffix}"
    done
  fi
  file="${HARNESS_DATA}/events/$(printf '%012d' "${seq}").json"
  printf '%s' "${data}" | jq -c --arg kind "${kind}" --arg actor "${actor}" --arg id "${identity}" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson seq "${seq}" '{seq:$seq,id:$id,actor:$actor,kind:$kind,data:.,date:$date}' | atomic_write "${file}" || return
  printf '%s\n' "${seq}" | atomic_write "${HARNESS_DATA}/index/${identity}" || return
  printf '%s\n' "${seq}" | atomic_write "${HARNESS_DATA}/HEAD" || return
  cat "${file}"
}

store_submit() (
  local text="$1" actor="${2:-main}" message_id="${3:-}" identity='' data seq file result
  if [[ -z "${text}" ]] || ! valid_id "${actor}" || { [[ -n "${message_id}" ]] && ! valid_id "${message_id}"; }; then
    printf 'invalid message text, actor, or message id\n' >&2; return 64
  fi
  exec 7>"${HARNESS_DATA}/locks/journal"; flock 7
  _store_recover_locked || return
  if [[ -n "${message_id}" ]]; then
    identity="client-$(printf '%s' "${actor}:${message_id}" | sha256sum | cut -d' ' -f1)"
    # Matching pre-namespace user records remain retryable without migration.
    # A namespaced retry takes precedence over an unrelated raw/generated ID.
    if [[ ! -f "${HARNESS_DATA}/index/${identity}" && -f "${HARNESS_DATA}/index/${message_id}" ]]; then
      seq="$(cat "${HARNESS_DATA}/index/${message_id}")" || return
      file="${HARNESS_DATA}/events/$(printf '%012d' "${seq}").json"
      if jq -e --arg a "${actor}" '.kind=="message" and .actor==$a and .data.kind=="user" and .data.message_id==null' "${file}" >/dev/null; then
        printf '%s' "${text}" | jq -eRs --slurpfile event "${file}" '.==$event[0].data.text' >/dev/null || {
          printf 'message id already used with different text\n' >&2; return 65
        }
        jq -c '{id,seq}' "${file}"; return
      fi
    fi
    _store_client_identity "${message_id}" && { printf 'client journal IDs cannot be submitted as message IDs\n' >&2; return 64; }
  fi
  data="$(printf '%s' "${text}" | jq -Rs --arg id "${message_id}" '{kind:"user",text:.} + (if $id=="" then {} else {message_id:$id} end)')" || return
  result="$(_store_publish_locked message "${actor}" "${data}" "${identity}" client)" || return
  printf '%s' "${result}" | jq -c --arg id "${message_id}" '{id:(if $id=="" then .id else $id end),seq}'
)

store_cancel() { store_emit cancel "${1:-main}" '{}' | jq -c '{id,seq}'; }

store_status() {
  local components='{"web":false,"reactor":false}' file name value queued=0 running=0 jobs_queued=0 jobs_running=0
  for file in "${HARNESS_DATA}/components/"*.json; do
    [[ -f "${file}" ]] || continue
    name="${file##*/}"; name="${name%.json}"; value=false
    if process_alive "$(jq -r '.pid' "${file}")" "$(jq -r '.start' "${file}")"; then value=true; fi
    components="$(printf '%s' "${components}" | jq -c --arg n "${name}" --argjson v "${value}" '.[$n]=$v')"
  done
  for file in "${HARNESS_DATA}/queue/requests/"*/*.json; do
    [[ -f "${file}" ]] || continue
    name="$(jq -r '.id' "${file}")"
    if ( exec 8>"${HARNESS_DATA}/locks/request-${name}"; flock -n 8 ); then queued=$((queued+1)); else running=$((running+1)); fi
  done
  for file in "${HARNESS_DATA}/queue/jobs/"*.json; do
    [[ -f "${file}" ]] || continue
    name="$(jq -r '.id' "${file}")"
    if ( exec 8>"${HARNESS_DATA}/locks/job-${name}"; flock -n 8 ); then jobs_queued=$((jobs_queued+1)); else jobs_running=$((jobs_running+1)); fi
  done
  jq -c --argjson components "${components}" --argjson q "${queued}" --argjson r "${running}" --argjson jq "${jobs_queued}" --argjson jr "${jobs_running}" '{cursor,actors:(.actors|[.[]|{id,name,parent,status,pending_jobs:(.pending_jobs|length)}]),components:$components,requests:{queued:$q,running:$r},jobs:{queued:$jq,running:$jr}}' "${HARNESS_DATA}/state.json"
}

store_feed() {
  local after="${1:-0}" before="${2:-0}" limit="${3:-100}" seq head cursor count=0 events='[]' file event direction=-1 more=false
  [[ "${after}" =~ ^[0-9]{1,12}$ && "${before}" =~ ^[0-9]{1,12}$ && "${limit}" =~ ^[0-9]{1,3}$ ]] || return 1
  after=$((10#$after)); before=$((10#$before)); limit=$((10#$limit)); (( limit>=1 && limit<=200 )) || return 1
  head="$(cat "${HARNESS_DATA}/HEAD")"; cursor="${head}"; seq="${head}"
  if (( after>0 )); then seq=$((after+1)); direction=1; cursor="${after}"; fi
  if (( before>0 )); then seq=$((before-1)); (( seq>head )) && seq="${head}"; fi
  while (( seq>0 && seq<=head )); do
    file="${HARNESS_DATA}/events/$(printf '%012d' "${seq}").json"
    if [[ -f "${file}" ]]; then
      event="$(jq -c 'select(.actor=="main" and (.kind=="message" or .kind=="assistant" or .kind=="tool" or .kind=="error"))' "${file}")"
      if [[ -n "${event}" ]]; then
        events="$(printf '%s\n%s' "${events}" "${event}" | jq -cs '.[0]+[.[1]]')"; count=$((count+1))
      fi
    fi
    (( direction==1 )) && cursor="${seq}"
    seq=$((seq+direction))
    if (( count>=limit )); then (( seq>0 && seq<=head )) && more=true; break; fi
  done
  printf '%s' "${events}" | jq -c --argjson cursor "${cursor}" --argjson more "${more}" --argjson status "$(store_status)" '{events:sort_by(.seq),cursor:$cursor,has_more:$more,status:$status}'
}
