#!/usr/bin/env bash
# A real projection-budget boundary must defer side effects until controls drain.
# shellcheck disable=SC1091,SC2154
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
HARNESS_ROOT="$(cd "${HARNESS_ROOT}" && pwd)"
export HARNESS_ROOT
source "${HARNESS_ROOT}/lib/bootstrap.sh"
source "${HARNESS_ROOT}/lib/store.sh"
source "${HARNESS_ROOT}/lib/runtime.sh"
store_init

state_update '.actors.main.status="ready" | .actors.main.inbox=[1] | .actors.main.pending_jobs=["held-job"] | .jobs["held-job"]={id:"held-job",actor:"main",kind:"tool"}'
printf '{}\n' > "${HARNESS_DATA}/queue/jobs/held-job.json"

# Batch-build an isolated journal; the production limit remains 1,000. Padding
# needs only cursor projection, and cancellation is the first unprojected record.
seq=0
while IFS= read -r event; do
  seq=$((seq+1))
  printf '%s\n' "${event}" > "${HARNESS_DATA}/events/$(printf '%012d' "${seq}").json"
done < <(jq -cn 'range(1;1002) as $seq | {seq:$seq,id:("backlog-"+($seq|tostring)),actor:"main",kind:(if $seq==1001 then "cancel" else "fixture.padding" end),data:{},date:"2026-10-08T00:00:00Z"}')
printf '1001\n' | atomic_write "${HARNESS_DATA}/HEAD"

# Stub only execution boundaries. Applying the real cancellation must remove
# the executable queue and ready input before any boundary can consume them.
boundaries="${_tmpdir}/boundaries"
effects="${_tmpdir}/effects"
runtime_launch_jobs() {
  printf 'jobs:%s\n' "$(jq -r '.cursor' "${HARNESS_DATA}/state.json")" >> "${boundaries}"
  [[ ! -f "${HARNESS_DATA}/queue/jobs/held-job.json" ]] || printf 'old tool launched\n' >> "${effects}"
}
runtime_schedule_actor() {
  printf 'turn:%s:%s\n' "$1" "$(jq -r '.cursor' "${HARNESS_DATA}/state.json")" >> "${boundaries}"
  [[ "$(state_actor "$1" | jq -r '.status')" != ready ]] || printf 'old turn scheduled\n' >> "${effects}"
}
runtime_schedule_summaries() {
  printf 'summary:%s:%s\n' "$1" "$(jq -r '.cursor' "${HARNESS_DATA}/state.json")" >> "${boundaries}"
}

runtime_tick
assert_eq 'first tick uses the production projection budget' "$(jq -r '.cursor' "${HARNESS_DATA}/state.json")" 1000
[[ ! -f "${boundaries}" && ! -f "${effects}" ]] || {
  printf 'FAIL: side effects or scheduling ran with cancellation still unprojected\n' >&2
  cat "${boundaries}" "${effects}" >&2
  exit 1
}
assert_eq 'queued work waits for the control event' "$(state_actor main | jq -r '.status')" ready

runtime_tick
assert_eq 'next tick drains cancellation' "$(jq -r '.cursor' "${HARNESS_DATA}/state.json")" 1001
assert_eq 'cancellation is applied before scheduling resumes' "$(state_actor main | jq -r '.status')" cancelled
assert_eq 'cancellation clears queued work' "$(jq '.jobs|length' "${HARNESS_DATA}/state.json")" 0
[[ ! -f "${effects}" && ! -f "${HARNESS_DATA}/queue/jobs/held-job.json" ]]
assert_eq 'all execution boundaries resume after the backlog drains' "$(cat "${boundaries}")" $'jobs:1001\nturn:main:1001\nsummary:main:1001'

printf 'PASS: bounded projection defers side effects and scheduling until cancellation is applied\n'
