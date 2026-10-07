#!/usr/bin/env bash
# Test: pane/stream death kills the background agent_loop process group.
# set -m puts the loop in its own group that does NOT receive pane closure's
# SIGHUP — without an explicit kill, a closed pane leaves a headless agent
# still running tools and committing (the lingering-writer bug: work landed
# in worktrees 25 minutes after the caller recorded a timeout).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_HOME="${_tmpdir}/home"
mkdir -p "${HARNESS_HOME}/hooks.d/start"
# A start hook that lingers: the "agent" mid-work when the pane dies.
cat > "${HARNESS_HOME}/hooks.d/start/05-slow" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
# argv carries the probe marker so pgrep -f can see the lingering process
bash -c 'sleep 30; true # streamloop-probe'
HOOK
chmod +x "${HARNESS_HOME}/hooks.d/start/05-slow"
# Keep only our hooks: override the sources walker by basename.
mkdir -p "${HARNESS_HOME}/hooks.d/sources"
cat > "${HARNESS_HOME}/hooks.d/sources/30-walk-dirs" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
jq -n --arg h "${HARNESS_HOME}" '{sources: [$h]}'
HOOK
chmod +x "${HARNESS_HOME}/hooks.d/sources/30-walk-dirs"

# Run stream (as a pane would) and kill it the way pane closure does: SIGHUP.
HARNESS_ROOT="${HARNESS_ROOT}" HARNESS_SESSIONS="${HARNESS_SESSIONS}" \
  HARNESS_PROVIDER=mock HARNESS_SESSION="${HARNESS_SESSION}" \
  "${HARNESS_ROOT}/plugins/core/commands/stream" "${HARNESS_SESSION##*/}" \
  >/dev/null 2>&1 &
stream_pid=$!

for _ in $(seq 1 50); do
  pgrep -f '^bash -c sleep 30; true # streamloop-probe$' >/dev/null 2>&1 && break
  sleep 0.1
done
pgrep -f '^bash -c sleep 30; true # streamloop-probe$' >/dev/null 2>&1 \
  || { echo "FAIL: probe never started"; kill ${stream_pid} 2>/dev/null; exit 1; }

kill -HUP "${stream_pid}" 2>/dev/null || true

# The loop group must die with the pane, not linger.
for _ in $(seq 1 50); do
  pgrep -f '^bash -c sleep 30; true # streamloop-probe$' >/dev/null 2>&1 || break
  sleep 0.1
done
if pgrep -f '^bash -c sleep 30; true # streamloop-probe$' >/dev/null 2>&1; then
  pkill -f 'streamloop-probe' 2>/dev/null || true
  echo "FAIL: agent_loop survived pane death (lingering writer)"
  exit 1
fi

wait "${stream_pid}" 2>/dev/null || true
echo "PASS"