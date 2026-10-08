#!/usr/bin/env bash
# Setup failures use the same durable retry gate as failed summary calls.
# shellcheck disable=SC1091,SC2154
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
HARNESS_ROOT="$(cd "${HARNESS_ROOT}" && pwd)"
export HARNESS_ROOT HARNESS_LIVE_ROOT="${HARNESS_ROOT}"
export HARNESS_PROVIDER=fixture HARNESS_MODEL='' HARNESS_SUMMARY_PROVIDER=missing-summary-provider
mkdir -p "${HARNESS_HOME}/providers"
cat > "${HARNESS_HOME}/providers/fixture" <<'PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --defaults) printf 'model=fixture-model\n' ;;
  --ready) exit 0 ;;
  *) echo 'unexpected inference in setup-only test' >&2; exit 1 ;;
esac
PROVIDER
chmod +x "${HARNESS_HOME}/providers/fixture"
source "${HARNESS_ROOT}/lib/bootstrap.sh"
source "${HARNESS_ROOT}/lib/store.sh"
source "${HARNESS_ROOT}/lib/memory.sh"
source "${HARNESS_ROOT}/lib/runtime.sh"
store_init

apply_input() {
  local event
  event="$(store_emit message main "$(printf '%s' "$1" | jq -Rs '{kind:"user",text:.}')" "$2")"
  runtime_apply_event "${event}"
}
schedule_summaries() {
  local _runtime_provider=fixture _runtime_model=''
  runtime_schedule_summaries main
}
schedule_actor() {
  local _runtime_provider=fixture _runtime_model=''
  runtime_schedule_actor main
}
retry="${HARNESS_DATA}/actors/main/summary-0-0.json"

apply_input "$(jq -nr '"long original "*100')" first-input
# Its foreground turn has finished; its long memory leaf still needs a summary.
state_update '.actors.main.inbox=[] | .actors.main.round=1'
schedule_summaries
assert_file_exists "${retry}"
assert_json '.failed' "$(cat "${retry}")" true
assert_json '.attempt' "$(cat "${retry}")" 1
assert_eq 'setup failure emits one visible error' "$(store_feed | jq '[.events[]|select(.kind=="error" and (.data.text|contains("missing-summary-provider")))]|length')" 1
assert_eq 'setup failure creates no unusable provider request' "$(find "${HARNESS_DATA}/queue/requests/1-summary" -type f | wc -l | tr -d ' ')" 0
head="$(cat "${HARNESS_DATA}/HEAD")"
schedule_summaries
assert_eq 'same wake does not emit the error again' "$(cat "${HARNESS_DATA}/HEAD")" "${head}"
assert_json '.attempt' "$(cat "${retry}")" 1

apply_input 'new task' second-input
schedule_actor
assert_json '.actors.main.status' "$(cat "${HARNESS_DATA}/state.json")" blocked_memory
schedule_summaries
assert_json '.attempt' "$(cat "${retry}")" 2
assert_eq 'new input retries once and reports its failure' "$(store_feed | jq '[.events[]|select(.kind=="error")]|length')" 2
head="$(cat "${HARNESS_DATA}/HEAD")"
schedule_summaries
assert_eq 'retry failure is gated at the new wake' "$(cat "${HARNESS_DATA}/HEAD")" "${head}"

export HARNESS_SUMMARY_PROVIDER=fixture
apply_input 'retry after fixing setup' third-input
schedule_summaries
queued="$(jq -sc '[.[]|select(.kind=="request.queued" and .data.kind=="summary")]|last' "${HARNESS_DATA}/events/"*.json)"
assert_json '.data.id' "${queued}" summary-main-0-0-2
assert_json '.data.provider' "${queued}" fixture
runtime_apply_event "${queued}"
request="$(printf '%s' "${queued}" | jq -r '.data.id')"
completed="$(store_emit request.completed main "$(jq -cn --arg id "${request}" '{id:$id,response:{blocks:[{type:"text",text:"user: the retained original task"}],stop:"end",usage:{}}}')" completed-summary)"
runtime_apply_event "${completed}"
memory_ready main
[[ ! -f "${retry}" ]] || { echo 'FAIL: completed summary retained failed retry state' >&2; exit 1; }
schedule_actor
resumed="$(jq -sc '[.[]|select(.kind=="request.queued" and .data.kind=="turn")]|last' "${HARNESS_DATA}/events/"*.json)"
assert_json '.data.actor' "${resumed}" main
runtime_apply_event "${resumed}"
assert_json '.actors.main.status' "$(cat "${HARNESS_DATA}/state.json")" running
printf 'PASS: visible summary setup errors, blocked-memory status, gated retries, and recovery\n'
