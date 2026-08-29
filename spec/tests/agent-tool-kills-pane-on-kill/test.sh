#!/usr/bin/env bash
# Test: the agent tool kills its pane when the tool process itself is killed
# (dispatcher wrapper expiry, manual kill). Pre-fix, an externally killed
# agent tool leaked a fully live subagent pane that kept working and
# committing long after the caller recorded a timeout (lingering writers).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

agent_tool="${HARNESS_ROOT}/plugins/subagents/tools/agent"
export TMUX="fake-tmux"
export HARNESS_CWD="${_tmpdir}/work"; mkdir -p "${HARNESS_CWD}"

fakebin="${_tmpdir}/bin"; mkdir -p "${fakebin}"
# Fake tmux: log every invocation. split-window starts a real long-running
# child so the pane is genuinely "live"; list-panes reports it alive so the
# tool's poll loop keeps waiting (until we kill the tool).
cat > "${fakebin}/tmux" <<'FAKE'
#!/usr/bin/env bash
log="${TMUX_LOG:?}"
printf '%s %s\n' "$(basename "$0")" "$*" >> "${log}"
case "$1" in
  split-window) sleep 30 >/dev/null 2>&1 & echo '%pane1' ;;
  list-panes)   kill -0 "${PANE_CHILD_PID:-0}" 2>/dev/null && exit 0 || exit 1 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "${fakebin}/tmux"
export PATH="${fakebin}:${PATH}"
export TMUX_LOG="${_tmpdir}/tmux.log"

# Run the tool, wait for it to settle into its pane-poll loop, then kill it
# the way the dispatcher wrapper would (TERM).
echo '{"prompt":"work"}' | "${agent_tool}" --exec >/dev/null 2>&1 &
tool_pid=$!
for _ in $(seq 1 50); do
  [[ -s "${TMUX_LOG}" ]] && grep -q split-window "${TMUX_LOG}" && break
  sleep 0.1
done
PANE_CHILD_PID="$(pgrep -f "^sleep 30$" | head -1)"
export PANE_CHILD_PID
sleep 0.5

kill -TERM "${tool_pid}" 2>/dev/null || true
wait "${tool_pid}" 2>/dev/null || true

# The tool must have killed the pane on its way out.
grep -q 'kill-pane' "${TMUX_LOG}" || { echo "FAIL: pane not killed on tool TERM; log:"; cat "${TMUX_LOG}"; exit 1; }
pkill -f '^sleep 30$' 2>/dev/null || true

echo "PASS"