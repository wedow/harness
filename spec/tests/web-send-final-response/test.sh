#!/usr/bin/env bash
# A message inserted after the final assemble needs a follow-up turn. A
# message included by a later assemble must not trigger a duplicate turn.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"

sid="20260101-000000-1"
dir="${HARNESS_SESSIONS}/${sid}"
mkdir -p "${dir}/messages"
cat > "${dir}/messages/0001-user.md" <<'MSG'
---
role: user
seq: 0001
---
first
MSG
printf '0001\n' > "${dir}/.assembled_user_seqs"

# Fake provider run: first invocation waits at the final response boundary.
# The follower writes its own assembled marker when it starts.
stub="${_tmpdir}/stub/plugins/core/commands/agent"
mkdir -p "$(dirname "${stub}")"
cat > "${stub}" <<'STUB'
#!/usr/bin/env bash
dir="${HARNESS_SESSIONS}/$1"
printf 'run\n' >> "${RUNS_LOG}"
if [[ ! -f "${RUN_FIRST_DONE}" ]]; then
  touch "${RUN_FIRST_READY}"
  while [[ ! -f "${RUN_FIRST_DONE}" ]]; do sleep 0.02; done
else
  last="$(ls -1 "${dir}/messages/"*-user.md | sort -n | tail -1)"
  basename "${last}" | cut -d- -f1 > "${dir}/.assembled_user_seqs"
fi
STUB
chmod +x "${stub}"
_HS="${_tmpdir}/runner"
cat > "${_HS}" <<'RUN'
#!/usr/bin/env bash
shift
exec "${RUN_STUB}" "$@"
RUN
chmod +x "${_HS}"
export RUN_STUB="${stub}" RUNS_LOG="${_tmpdir}/runs" RUN_FIRST_READY="${_tmpdir}/ready" RUN_FIRST_DONE="${_tmpdir}/done"

_launch_agent "${sid}" "first"
for _ in {1..100}; do [[ -f "${RUN_FIRST_READY}" ]] && break; sleep 0.02; done
[[ -f "${RUN_FIRST_READY}" ]] || { echo 'FAIL: first driver did not start'; exit 1; }

# Simulate the POST while that driver is still in its provider call.
BODY='message=late'
handle_send "${sid}"
assert_file_contains "${dir}/messages/0002-user.md" late
touch "${RUN_FIRST_DONE}"
wait
assert_eq 'late message gets a follow-up run' "$(grep -c '^run$' "${RUNS_LOG}")" 2

# Simulate a mid-turn insert that the first run later assembled. The queued
# follower should notice the marker and skip the provider entirely.
: > "${RUNS_LOG}"
printf '0001\n0002\n' > "${dir}/.assembled_user_seqs"
rm -f "${RUN_FIRST_DONE}" "${RUN_FIRST_READY}"
_launch_agent "${sid}" "first"
for _ in {1..100}; do [[ -f "${RUN_FIRST_READY}" ]] && break; sleep 0.02; done
[[ -f "${RUN_FIRST_READY}" ]] || { echo 'FAIL: second driver did not start'; exit 1; }
BODY='message=included'
handle_send "${sid}"
printf '0001\n0002\n0003\n' > "${dir}/.assembled_user_seqs"
touch "${RUN_FIRST_DONE}"
wait
assert_eq 'already assembled message avoids a duplicate run' "$(grep -c '^run$' "${RUNS_LOG}")" 1

# A web writer may claim 0002 and delay publishing it. A later user writer
# publishes 0003 first, and the assembler records 0001 and 0003. The max
# sequence alone would incorrectly call 0002 consumed.
printf '0001\n0003\n' > "${dir}/.assembled_user_seqs"
_web_unassembled_user "${dir}" || { echo 'FAIL: missed unpublished-at-assemble user 0002'; exit 1; }

# Sequence numbers can grow beyond the four-digit padding width. The latest
# numeric user message must win even when lexical filename order reverses.
cp "${dir}/messages/0001-user.md" "${dir}/messages/9999-user.md"
cp "${dir}/messages/0001-user.md" "${dir}/messages/10000-user.md"
printf '0001\n0002\n0003\n9999\n' > "${dir}/.assembled_user_seqs"
_web_unassembled_user "${dir}" || { echo 'FAIL: missed user sequence 10000'; exit 1; }
printf '0001\n0002\n0003\n9999\n10000\n' > "${dir}/.assembled_user_seqs"
if _web_unassembled_user "${dir}"; then echo 'FAIL: repeated user sequence 10000'; exit 1; fi
for provider in openai anthropic chatgpt; do
  marker="$(printf '{}' | HARNESS_SESSION="${dir}" "${HARNESS_ROOT}/plugins/${provider}/hooks.d/assemble/10-messages" | jq -r '._assembled_user_seqs | index("10000")')"
  [[ "${marker}" != null ]] || { echo "FAIL: ${provider} omitted user sequence 10000"; exit 1; }
done

echo PASS
