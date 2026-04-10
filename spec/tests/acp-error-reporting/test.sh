#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSIONS="${_tmpdir}/sessions"
export HARNESS_HOME="${_tmpdir}/home"
export HARNESS_MODEL=""
mkdir -p "${HARNESS_SESSIONS}" "${HARNESS_HOME}"

# Pre-create a session directory so we can skip session/new
sid="test-error-session"
sdir="${HARNESS_SESSIONS}/${sid}"
mkdir -p "${sdir}/messages"
printf 'id=%s\nmodel=test\nprovider=mock\ncreated=2026-01-01\ncwd=/tmp\n' "${sid}" > "${sdir}/session.conf"

# Create a start hook that immediately fails, triggering the error path.
# The error hook writes {"type":"error","msg":"..."} to .stream,
# then agent_loop appends {"type":"done"}.
mkdir -p "${HARNESS_HOME}/hooks.d/start"
cat > "${HARNESS_HOME}/hooks.d/start/05-fail" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
echo '{"error":"simulated failure"}' >&2
exit 1
HOOK
chmod +x "${HARNESS_HOME}/hooks.d/start/05-fail"

acp="${HARNESS_ROOT}/plugins/core/commands/acp"

# Send session/prompt with the pre-created session ID.
# The agent will hit the failing start hook, produce an error event, then done.
out="$(printf '{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"%s","prompt":[{"text":"hello"}]}}\n' \
  "${sid}" | run_with_timeout 15 "$acp" 2>/dev/null)" || true

# Find the response with id:1 (skip any notification lines)
prompt_response=""
while IFS= read -r _line; do
  _id="$(echo "${_line}" | jq -r '.id // empty' 2>/dev/null)" || continue
  [[ "${_id}" == "1" ]] && { prompt_response="${_line}"; break; }
done <<< "${out}"

[[ -n "${prompt_response}" ]] || { echo "FAIL: no response for session/prompt (id:1)"; exit 1; }

# The bug: stopReason is "end_turn" even though the agent errored.
# When an error event occurs in .stream, the ACP adapter silently ignores it
# (line 135: `error) ;;`) and defaults to stopReason "end_turn".
# The fix should report an error stop reason, not "end_turn".
stop_reason="$(echo "${prompt_response}" | jq -r '.result.stopReason // empty')"

if [[ "${stop_reason}" == "end_turn" ]]; then
  echo "FAIL: stopReason is 'end_turn' but agent errored — error was silently swallowed"
  exit 1
fi

echo "PASS"
