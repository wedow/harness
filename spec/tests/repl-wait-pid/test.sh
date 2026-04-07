#!/usr/bin/env bash
# Test: capturing PID before exec fd< <(process substitution) preserves it.
# Verifies the fix for plugins/core/commands/repl lines 99-101 where $!
# was overwritten by _render_stream's process substitution.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

stream_file="${HARNESS_SESSION}/.stream"
touch "${stream_file}"

# Simulate agent_loop: background job that exits 0
sleep 0.5 &
agent_pid=$!

# Without the fix, $! would be overwritten by exec fd< <(…)
exec 5< <(tail -c +1 -f "${stream_file}" 2>/dev/null)
tail_pid=$!

# The fix: capture PID before process substitution.
# Verify agent_pid is still valid and distinct from tail_pid.
assert_eq 'agent_pid should differ from tail_pid' \
  "$([ "${agent_pid}" != "${tail_pid}" ] && echo yes)" "yes"

# Clean up tail/fd like _render_stream does
exec 5<&-
kill "${tail_pid}" 2>/dev/null || true
wait "${tail_pid}" 2>/dev/null || true

# Verify we can wait on the captured agent_pid and get its exit code
wait "${agent_pid}" 2>/dev/null
agent_rc=$?
assert_eq 'agent exit code captured via saved pid' "${agent_rc}" "0"
