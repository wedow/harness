#!/usr/bin/env bash
# Test: agent_loop writes {"type":"done"} even when killed by signal
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_HOME="${_tmpdir}/home"
mkdir -p "${HARNESS_HOME}"

# Create a start hook that sleeps (gives us time to kill)
mkdir -p "${HARNESS_HOME}/hooks.d/start"
cat > "${HARNESS_HOME}/hooks.d/start/05-slow" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
sleep 30
HOOK
chmod +x "${HARNESS_HOME}/hooks.d/start/05-slow"

session_dir="${HARNESS_SESSION}"
touch "${session_dir}/.stream"

# Run agent_loop in background subshell
bash -c "
  source '${HARNESS_ROOT}/bin/harness'
  _refresh_sources
  agent_loop '${session_dir}'
" &>/dev/null &
agent_pid=$!

# Wait for agent to start, then kill it
sleep 0.3
kill -TERM "${agent_pid}" 2>/dev/null || true
wait "${agent_pid}" 2>/dev/null || true

# Give a moment for trap to flush
sleep 0.2

# Check that .stream contains a done event
if [[ ! -s "${session_dir}/.stream" ]]; then
  echo "FAIL: .stream is empty after agent killed"
  exit 1
fi

last_line="$(tail -1 "${session_dir}/.stream")"
last_type="$(echo "${last_line}" | jq -r '.type // empty' 2>/dev/null)" || true

assert_eq "done event written after SIGTERM" "${last_type}" "done"

echo "PASS"
