#!/usr/bin/env bash
# Test: REPL SIGINT trap kills the whole agent process group and the stream tail.
# Regression: Ctrl+C previously only killed the immediate shell, leaving child
# processes like slow hooks and tail running, which made the REPL hang.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_HOME="${_tmpdir}/home"
mkdir -p "${HARNESS_HOME}/hooks.d/start"

cat > "${HARNESS_HOME}/hooks.d/start/05-slow" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
sleep 30
HOOK
chmod +x "${HARNESS_HOME}/hooks.d/start/05-slow"

repl="${HARNESS_ROOT}/plugins/core/commands/repl"
session_name="$(basename "${HARNESS_SESSION}")"

coproc REPL_PROC { bash "${repl}" "${session_name}" 2>/dev/null; }
repl_pid=$REPL_PROC_PID
exec 7>&"${REPL_PROC[1]}"

printf 'hello\n' >&7
sleep 1
kill -INT "${repl_pid}" 2>/dev/null || true
exec 7>&-
wait "${repl_pid}" 2>/dev/null || true

if kill -0 "${repl_pid}" 2>/dev/null; then
  echo "FAIL: repl still running after SIGINT"
  kill -TERM "${repl_pid}" 2>/dev/null || true
  wait "${repl_pid}" 2>/dev/null || true
  exit 1
fi

if pgrep -P "${repl_pid}" >/dev/null 2>&1; then
  echo "FAIL: repl left child processes running after SIGINT"
  pgrep -P "${repl_pid}" || true
  exit 1
fi

echo "PASS"