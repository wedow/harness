#!/usr/bin/env bash
# Test: REPL SIGINT trap kills the whole agent process group.
# Regression: Ctrl+C previously only killed the immediate shell, leaving
# child processes like slow hooks and the stream tail running.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_HOME="${_tmpdir}/home"
mkdir -p "${HARNESS_HOME}/hooks.d/start"

marker="${_tmpdir}/slow.started"
cat > "${HARNESS_HOME}/hooks.d/start/05-slow" <<HOOK
#!/usr/bin/env bash
echo running > "${marker}"
cat >/dev/null
sleep 30
HOOK
chmod +x "${HARNESS_HOME}/hooks.d/start/05-slow"

repl="${HARNESS_ROOT}/plugins/core/commands/repl"
session_name="$(basename "${HARNESS_SESSION}")"

# pty_spawn runs the repl inside a pty. Without one, bash backgrounds the repl
# with SIGINT set to SIG_IGN and `trap _handle_sigint INT` is silently a no-op.
pty_spawn "printf 'hello\n' | bash '${repl}' '${session_name}' >/dev/null 2>&1" &
repl_pid=$!

# Don't send SIGINT until the slow hook has actually started — otherwise the
# test passes trivially when the repl exits for unrelated reasons.
for _ in $(seq 1 50); do
  [[ -f "${marker}" ]] && break
  sleep 0.1
done
[[ -f "${marker}" ]] || {
  echo "FAIL: slow hook never started"
  kill -KILL -- "-${repl_pid}" 2>/dev/null || true
  exit 1
}

kill -INT -- "-${repl_pid}" 2>/dev/null || kill -INT "${repl_pid}" 2>/dev/null || true

for _ in $(seq 1 30); do
  kill -0 "${repl_pid}" 2>/dev/null || break
  sleep 0.1
done

if kill -0 "${repl_pid}" 2>/dev/null; then
  echo "FAIL: repl still running after SIGINT"
  kill -KILL -- "-${repl_pid}" 2>/dev/null || true
  exit 1
fi

# Slow hook should have died with the agent group.
if pgrep -f "${HARNESS_HOME}/hooks.d/start/05-slow" >/dev/null; then
  echo "FAIL: slow hook still running after SIGINT"
  pkill -KILL -f "${HARNESS_HOME}/hooks.d/start/05-slow" 2>/dev/null || true
  exit 1
fi

echo "PASS"
