#!/usr/bin/env bash
# Immutable events are authoritative; state and queues are replayable projections.
set -euo pipefail

store_init() (
  umask 077
  mkdir -p "${HARNESS_HOME}" "${HARNESS_DATA}"/{events,index,locks,components,logs,actors,code,queue/requests/0-turn,queue/requests/1-summary,queue/jobs,requests,jobs}
  exec 7>"${HARNESS_DATA}/locks/journal"
  flock 7
  if [[ ! -f "${HARNESS_DATA}/HEAD" ]]; then printf '0\n' | atomic_write "${HARNESS_DATA}/HEAD"; fi
  local seq file identity
  seq="$(cat "${HARNESS_DATA}/HEAD")"
  while file="${HARNESS_DATA}/events/$(printf '%012d' "$((seq+1))").json"; [[ -f "${file}" ]]; do
    seq=$((seq+1)); identity="$(jq -r '.id' "${file}")"
    printf '%s\n' "${seq}" | atomic_write "${HARNESS_DATA}/index/${identity}"
  done
  printf '%s\n' "${seq}" | atomic_write "${HARNESS_DATA}/HEAD"
  if [[ ! -f "${HARNESS_DATA}/state.json" ]]; then
    jq -cn --arg cwd "${HARNESS_CWD}" '{cursor:0,actors:{main:{id:"main",name:"main",parent:null,cwd:$cwd,inbox:[],ledger:[],request:null,turn:null,pending_jobs:[],status:"idle"}},requests:{},jobs:{}}' | atomic_write "${HARNESS_DATA}/state.json"
  fi
)

store_emit() (
  local kind="$1" actor="$2" data="$3" identity="${4:-}" seq file existing suffix=0
  valid_id "${actor}" || return 1
  [[ -z "${identity}" ]] || valid_id "${identity}" || return 1
  printf '%s' "${data}" | jq -e 'type == "object"' >/dev/null || return 1
  exec 7>"${HARNESS_DATA}/locks/journal"; flock 7
  seq="$(cat "${HARNESS_DATA}/HEAD")"
  # Recover a commit interrupted between event publication and HEAD/index.
  while file="${HARNESS_DATA}/events/$(printf '%012d' "$(( seq+1 ))").json"; [[ -f "${file}" ]]; do
    seq=$(( seq+1 )); existing="$(jq -r '.id' "${file}")"
    printf '%s\n' "${seq}" | atomic_write "${HARNESS_DATA}/index/${existing}"
  done
  printf '%s\n' "${seq}" | atomic_write "${HARNESS_DATA}/HEAD"
  if [[ -n "${identity}" && -f "${HARNESS_DATA}/index/${identity}" ]]; then
    existing="$(cat "${HARNESS_DATA}/index/${identity}")"
    file="${HARNESS_DATA}/events/$(printf '%012d' "${existing}").json"
    printf '%s' "${data}" | jq -e --arg k "${kind}" --arg a "${actor}" --slurpfile event "${file}" '. as $d | $event[0] | .kind==$k and .actor==$a and .data==$d' >/dev/null || { printf 'event ID already used with different content\n' >&2; return 1; }
    printf '%s\n' "${seq}" | atomic_write "${HARNESS_DATA}/HEAD"
    cat "${file}"; return
  fi
  seq=$((seq+1))
  if [[ -z "${identity}" ]]; then
    identity="event-${seq}"
    while [[ -f "${HARNESS_DATA}/index/${identity}" ]]; do
      suffix=$((suffix+1)); identity="event-${seq}-${suffix}"
    done
  fi
  file="${HARNESS_DATA}/events/$(printf '%012d' "${seq}").json"
  printf '%s' "${data}" | jq -c --arg kind "${kind}" --arg actor "${actor}" --arg id "${identity}" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson seq "${seq}" '{seq:$seq,id:$id,actor:$actor,kind:$kind,data:.,date:$date}' | atomic_write "${file}"
  printf '%s\n' "${seq}" | atomic_write "${HARNESS_DATA}/index/${identity}"
  printf '%s\n' "${seq}" | atomic_write "${HARNESS_DATA}/HEAD"
  cat "${file}"
)

store_submit() {
  local text="$1" actor="${2:-main}" identity="${3:-}" data
  [[ -n "${text}" ]] || { printf 'message is empty\n' >&2; return 1; }
  data="$(printf '%s' "${text}" | jq -Rs '{kind:"user",text:.}')"
  store_emit message "${actor}" "${data}" "${identity}" | jq -c '{id,seq}'
}

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
