#!/usr/bin/env bash
# bash-watchdog-orphan — a watchdog whose tool process dies mid-run must exit
# within a tick, not live out the agent-specified timeout. (Outage kills and
# stop buttons orphaned day-scale sleep timers before.)
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

tool="${HARNESS_ROOT}/plugins/core/tools/bash"
export HARNESS_CWD="${_tmpdir}"

# Unique timeout value. $! of the pipeline = the tool process itself.
# The leftover check is anchored (^...$): supervisor wrappers carry this
# script's text in their cmdlines and must not be counted.
echo '{"command":"sleep 3","timeout":597}' | "${tool}" --exec >/dev/null 2>&1 &
tool_pid=$!
sleep 0.5
kill -9 "${tool_pid}"   # simulate the agent-turn kill
wait "${tool_pid}" 2>/dev/null || true

# Old behavior: a `sleep 597` watchdog child lives ~10 minutes after the
# orphaning. New: gone within a tick of the parent's death.
sleep 3
# NB: || true — pgrep exits 1 on no-match and pipefail would abort here
leftover="$(pgrep -f '^sleep 597$' | wc -l | tr -d ' ' || true)"
assert_eq "orphaned-watchdog-exited" "${leftover:-0}" "0"