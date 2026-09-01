#!/usr/bin/env bash
# Test: a message sent mid-turn is INSERTED into the live conversation (picked
# up by the running loop at its next assemble, before the next LLM API call)
# instead of queueing a second driver for the remainder of a possibly
# hours-long turn. Idle sessions still spawn a driver.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

sessions="${_tmpdir}/sessions"
mkdir -p "${sessions}"
export HARNESS_SESSIONS="${sessions}"
source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"

runs="${_tmpdir}/runs.log"
# Stub driver at a path whose invocation matches the real driver signature
# (".../plugins/core/commands/agent <session-id> <msg>") so _driver_alive
# (pgrep) sees it. It holds the session lock like a real web driver.
_HS_DIR="${_tmpdir}/harness-stub/plugins/core/commands"
mkdir -p "${_HS_DIR}"
cat > "${_HS_DIR}/agent" <<'STUB'
#!/usr/bin/env bash
printf 'run %s\n' "$2" >> "${RUNS_LOG}"
exec 9>>"${HARNESS_SESSIONS}/$1/.lock"
flock 9
sleep 2
STUB
chmod +x "${_HS_DIR}/agent"
_HS="${_tmpdir}/harness-stub-run"
cat > "${_HS}" <<'RUN'
#!/usr/bin/env bash
# _HS is invoked as "<root> agent <id> <msg>"; drop the literal "agent"
shift
exec "${RUN_STUB_DIR}/plugins/core/commands/agent" "$@"
RUN
chmod +x "${_HS}"
export RUN_STUB_DIR="${_tmpdir}/harness-stub" RUNS_LOG="${runs}"

sid="20260101-000000-1"
mkdir -p "${sessions}/${sid}/messages"

# 1. Idle: send spawns a driver (which takes the lock for ~2s).
_launch_agent "${sid}" "first"
for _ in $(seq 1 50); do [[ -f "${runs}" ]] && break; sleep 0.1; done
[[ -f "${runs}" ]] || { echo "FAIL: driver never ran"; exit 1; }

# 2. While the driver holds the lock, a new message must be INSERTED into
#    messages/ immediately and must NOT spawn a second driver run.
before="$(grep -c '^run ' "${runs}" || true)"
dir="${sessions}/${sid}"
_insert_live_message "${dir}" "steer: use the fast path"
inserted="$(ls "${dir}/messages" | grep -c 'user\.md$')"
assert_eq "message inserted" "${inserted}" "1"
grep -q 'steer: use the fast path' "${dir}/messages/"*-user.md \
  || { echo "FAIL: message content wrong"; exit 1; }
sleep 1
after="$(grep -c '^run ' "${runs}" || true)"
assert_eq "no second driver" "${after}" "${before}"

# 3. handle_send routes correctly on both paths.
BODY="message=via+handle"
( BODY="message=via+handle" handle_send "${sid}" ) || true
ls "${dir}/messages" | grep -c 'user\.md$' | { read n; [[ "$n" == "2" ]] && echo ok; } \
  || { echo "FAIL: handle_send did not insert while running"; exit 1; }

echo "PASS"