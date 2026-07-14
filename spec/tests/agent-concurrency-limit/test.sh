#!/usr/bin/env bash
# Test: subagent provider calls sharing a root session queue behind one semaphore.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

send_hook="${HARNESS_ROOT}/plugins/core/hooks.d/send/10-send"
mock_src="${_tmpdir}/mock-src"
root_session="${_tmpdir}/root-session"
mkdir -p "${mock_src}/providers" "${root_session}" \
  "${_tmpdir}/session-a" "${_tmpdir}/session-b"
printf 'cwd=%s\n' "${_tmpdir}" > "${_tmpdir}/session-a/session.conf"
printf 'cwd=%s\n' "${_tmpdir}" > "${_tmpdir}/session-b/session.conf"

cat > "${mock_src}/providers/mock" <<'PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "${HARNESS_SESSION}")"
printf '%s\n' "${name}" >> "${AGENT_TEST_STARTED}"
while [[ ! -f "${AGENT_TEST_RELEASE}/${name}" ]]; do sleep 0.02; done
printf '{"stop":"end"}'
PROVIDER
chmod +x "${mock_src}/providers/mock"

started="${_tmpdir}/started"
release="${_tmpdir}/release"
run_id="current-run"
mkdir -p "${release}"
: > "${started}"

# A lock left by an earlier top-level run must not consume a slot in this run.
mkdir -p "${root_session}/.agent-slots/prior-run/1"
printf '%s\n' "$$" > "${root_session}/.agent-slots/prior-run/1/pid"

children=()
cleanup_children() {
  local pid
  for pid in "${children[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
}
trap cleanup_children EXIT

wait_for_started() {
  local expected="$1" label="$2"
  for _ in {1..100}; do
    [[ "$(wc -l < "${started}")" -ge "${expected}" ]] && return 0
    sleep 0.02
  done
  echo "FAIL: ${label}"
  return 1
}

run_send() {
  local session="$1" concurrency="${2:-1}"
  printf '{"messages":[]}' \
    | HARNESS_SESSION="${session}" \
      HARNESS_SOURCES="${mock_src}" \
      HARNESS_PROVIDER=mock \
      HARNESS_AGENT_SESSION_ROOT="${root_session}" \
      HARNESS_RUN_ID="${run_id}" \
      HARNESS_AGENT_CONCURRENCY="${concurrency}" \
      AGENT_TEST_STARTED="${started}" \
      AGENT_TEST_RELEASE="${release}" \
      "${send_hook}"
}

run_send "${_tmpdir}/session-a" > "${_tmpdir}/a.out" &
a_pid=$!
children+=("${a_pid}")
wait_for_started 1 "first provider call did not start"
failures=0
[[ -d "${root_session}/.agent-slots/${run_id}/1" ]] || {
  echo "FAIL: active provider call did not visibly own its run-scoped slot"
  failures=1
}

run_send "${_tmpdir}/session-b" > "${_tmpdir}/b.out" &
b_pid=$!
children+=("${b_pid}")
sleep 0.2
[[ "$(wc -l < "${started}")" -eq 1 ]] \
  || { echo "FAIL: second provider call started without waiting for the shared slot"; exit 1; }

touch "${release}/session-a"
wait_for_started 2 "queued provider call did not start after release"
touch "${release}/session-b"
wait "${a_pid}" "${b_pid}"

jq -e '.next_state == "receive"' "${_tmpdir}/a.out" >/dev/null
jq -e '.next_state == "receive"' "${_tmpdir}/b.out" >/dev/null
[[ ! -d "${root_session}/.agent-slots/${run_id}/1" ]] \
  || { echo "FAIL: concurrency slot was not released"; exit 1; }
[[ "${failures}" -eq 0 ]] || exit 1

echo "PASS"
