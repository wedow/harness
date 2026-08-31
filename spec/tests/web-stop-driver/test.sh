#!/usr/bin/env bash
# Test: the web stop control kills the ENTIRE driver tree — the run-lock fd
# identifies it (launcher, agent loop, provider curl, tools) — and cascades
# through the lifecycle traps: TERM reaches the agent tool, whose trap kills
# its pane, whose stream trap kills the subagent loop. Simulated here with a
# tree of processes all holding fd 9, including one in its own session.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

sessions="${_tmpdir}/sessions"
mkdir -p "${sessions}"
export HARNESS_SESSIONS="${sessions}"
source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"

sid="20260101-000000-1"
dir="${sessions}/${sid}"
mkdir -p "${dir}/messages"
: > "${dir}/.lock"

# Fake driver tree: launcher subshell holds fd 9; child and a setsid'd
# grandchild inherit it (like the bash tool's process-group-isolated
# commands). All must die on stop.
bash -c '
  exec 9>>"'${dir}'/.lock"
  flock 9
  bash -c "exec 9>&9; sleep 30; true # stopctl-child" &
  setsid bash -c "exec 9>&9; sleep 30; true # stopctl-grandchild" &
  sleep 30; true # stopctl-driver
' & launcher=$!

for _ in $(seq 1 50); do
  pgrep -f '^bash -c .*/stopctl' >/dev/null 2>&1 && pgrep -f 'stopctl-grandchild' >/dev/null 2>&1 && break
  sleep 0.1
done
pgrep -f 'stopctl-driver' >/dev/null 2>&1 || { echo "FAIL: driver tree never started"; kill ${launcher} 2>/dev/null; exit 1; }
_agent_running "${dir}" || { echo "FAIL: lock not held (tree broken)"; kill ${launcher} 2>/dev/null; exit 1; }

# 1. Stop button markup while running.
[[ "$(_stop_btn "${sid}")" == *'/stop'* ]] || { echo "FAIL: no stop action while running"; exit 1; }

# 2. Stop kills the whole tree and frees the lock.
_stop_agent "${sid}"
for _ in $(seq 1 50); do
  ! pgrep -f 'stopctl' >/dev/null 2>&1 && break
  sleep 0.1
done
if pgrep -f 'stopctl-driver|stopctl-child|stopctl-grandchild' >/dev/null 2>&1; then
  pkill -f stopctl 2>/dev/null || true
  echo "FAIL: driver tree survived stop"
  exit 1
fi
if _agent_running "${dir}"; then
  echo "FAIL: lock still held after stop"
  exit 1
fi

# 3. Idle sessions render a hidden stop button.
[[ "$(_stop_btn "${sid}")" == *'hidden'* ]] || { echo "FAIL: stop button visible while idle"; exit 1; }

wait "${launcher}" 2>/dev/null || true
echo "PASS"