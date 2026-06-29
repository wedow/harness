#!/usr/bin/env bash
# Test: parallel tool dispatcher bounds every dispatched tool with HARNESS_TOOL_TIMEOUT
# (gap-dispatch-wait fix). Pre-fix, only bash (HARNESS_TOOL_TIMEOUT) and agent
# (HARNESS_AGENT_TIMEOUT) self-bound. Every other tool dispatched during streaming
# (edit_file, read_file, write_file, skill, any user-plugin tool) had no wall-clock
# bound — a hung one blocked the dispatcher's inner `wait` → _cleanup_dispatch's
# `wait` → the send hook → call() → the orchestrator (same "needs SIGTERM" symptom
# as BUG-2, on a path the agent timeout cannot reach).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

send_hook="${HARNESS_ROOT}/plugins/core/hooks.d/send/10-send"

# Mock source dir: fake streaming provider + a hung tool with no internal timeout
mock_src="${_tmpdir}/mock_src"
mkdir -p "${mock_src}/providers" "${mock_src}/tools"

# Provider: the literal `--stream` token must appear so the send hook's
# `grep -q -- '--stream'` enables streaming mode. On exec, write one tool-call
# line to HARNESS_TOOL_FIFO (set up by the send hook), then return valid JSON.
cat > "${mock_src}/providers/mock" <<'PROV'
#!/usr/bin/env bash
# supports --stream
set -euo pipefail
if [[ -n "${HARNESS_TOOL_FIFO:-}" ]]; then
  printf '%s\n' '{"id":"c1","name":"hang_tool","input":{}}' >"${HARNESS_TOOL_FIFO}"
fi
printf '{"stop":"end"}'
PROV
chmod +x "${mock_src}/providers/mock"

# A user-plugin-style tool with NO internal timeout. Pre-fix, the dispatcher's
# unbounded `wait` blocks on this until the sleep finishes.
cat > "${mock_src}/tools/hang_tool" <<'TOOL'
#!/usr/bin/env bash
case "${1:-}" in
  --exec) sleep 60 ;;
  --schema) echo '{}' ;;
  --describe) echo 'hang tool' ;;
  *) ;;
esac
TOOL
chmod +x "${mock_src}/tools/hang_tool"

echo "cwd=${_tmpdir}" > "${HARNESS_SESSION}/session.conf"

export HARNESS_SOURCES="${mock_src}"
export HARNESS_PROVIDER="mock"
# Small per-tool bound so the test resolves quickly. Default is 120s; here we
# prove the dispatcher wraps the tool in this timeout instead of waiting on it.
export HARNESS_TOOL_TIMEOUT=2

start=$SECONDS
rc=0
out="$(echo '{"messages":[]}' | timeout 10 "${send_hook}" 2>&1)" || rc=$?
elapsed=$(( SECONDS - start ))

# Sweep any orphaned tool processes if the dispatcher was left stuck (pre-fix path)
pkill -f "${mock_src}/tools/hang_tool" 2>/dev/null || true

# Pre-fix: send hook hits outer timeout → rc=124, elapsed≈10s.
# Post-fix: tool killed at HARNESS_TOOL_TIMEOUT → rc=0, elapsed≈2s.
[[ "${rc}" -ne 124 ]] || { echo "FAIL: send hook hit outer timeout (rc=124); dispatcher did not bound hung tool (elapsed=${elapsed}s, out=${out})"; exit 1; }
[[ "${elapsed}" -lt 8 ]] || { echo "FAIL: send hook took too long (${elapsed}s); hung tool was not bounded (out=${out})"; exit 1; }

echo "PASS (rc=${rc}, elapsed=${elapsed}s)"
