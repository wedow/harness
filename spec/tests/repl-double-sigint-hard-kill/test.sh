#!/usr/bin/env bash
# Test: a second SIGINT forces immediate REPL exit.
# First SIGINT triggers graceful cleanup. If children ignore TERM and keep the
# REPL busy, a second SIGINT should hard-kill the REPL process group and exit.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_HOME="${_tmpdir}/home"
mkdir -p "${HARNESS_HOME}/hooks.d/start"

cat > "${HARNESS_HOME}/hooks.d/start/05-stubborn" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
trap '' TERM INT
sleep 30
HOOK
chmod +x "${HARNESS_HOME}/hooks.d/start/05-stubborn"

repl="${HARNESS_ROOT}/plugins/core/commands/repl"
session_name="$(basename "${HARNESS_SESSION}")"

script -q /dev/null -c "printf 'hello\n' | bash '${repl}' '${session_name}' >/dev/null 2>&1" &
repl_pid=$!
sleep 1

kill -INT -- "-${repl_pid}" 2>/dev/null || kill -INT "${repl_pid}" 2>/dev/null || true
sleep 0.2
kill -INT -- "-${repl_pid}" 2>/dev/null || kill -INT "${repl_pid}" 2>/dev/null || true

for _ in $(seq 1 20); do
  kill -0 "${repl_pid}" 2>/dev/null || break
  sleep 0.1
done

if kill -0 "${repl_pid}" 2>/dev/null; then
  echo "FAIL: repl still running after second SIGINT hard-kill"
  kill -KILL -- "-${repl_pid}" 2>/dev/null || kill -KILL "${repl_pid}" 2>/dev/null || true
  wait "${repl_pid}" 2>/dev/null || true
  exit 1
fi

echo "PASS"