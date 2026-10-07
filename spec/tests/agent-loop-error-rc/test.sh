#!/usr/bin/env bash
# Test: agent_loop and the commands that drive it propagate failure.
#
# The canary failure mode: a subagent's provider stream died mid-turn
# (curl --max-time cut a healthy slow stream). agent_loop broke out of the
# error state but returned 0; commands/stream then waited with `|| true` and
# exited 0, so the pane wrote .exit_code=0 and the agent tool extracted the
# last MID-TURN assistant message as if it were the subagent's final output
# — the "silent truncated transcript" orchestators kept hitting.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_HOME="${_tmpdir}/home"
mkdir -p "${HARNESS_HOME}"

# start hook fails -> loop enters error state -> error hook displays -> break
mkdir -p "${HARNESS_HOME}/hooks.d/start" "${HARNESS_HOME}/hooks.d/error"
cat > "${HARNESS_HOME}/hooks.d/start/05-boom" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
echo "boom: provider exploded" >&2
exit 1
HOOK
chmod +x "${HARNESS_HOME}/hooks.d/start/05-boom"
cat > "${HARNESS_HOME}/hooks.d/error/10-display" <<'HOOK'
#!/usr/bin/env bash
jq -n --arg m "boom" '{output: ("error: " + $m)}'
HOOK
chmod +x "${HARNESS_HOME}/hooks.d/error/10-display"

session_dir="${HARNESS_SESSION}"
touch "${session_dir}/.stream"

# 1. agent_loop itself returns non-zero on an error-state exit.
rc=0
bash -c "
  source '${HARNESS_ROOT}/bin/harness'
  _refresh_sources
  agent_loop '${session_dir}'
" >/dev/null 2>&1 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: agent_loop should return non-zero after error state"; exit 1; }

# 2. commands/agent (headless, inline branch) exits non-zero for the same.
rc=0
out="$(HARNESS_SESSION="${_tmpdir}/outer" \
  HARNESS_SOURCES="${HARNESS_HOME}" \
  HARNESS_PROVIDER=mock \
  "${HARNESS_ROOT}/plugins/core/commands/agent" "do x" 2>&1)" || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: commands/agent should exit non-zero, got: ${out}"; exit 1; }
[[ "${out}" == *"error: boom"* ]] || { echo "FAIL: expected error output, got: ${out}"; exit 1; }

# 3. agent tool (inline branch) surfaces the child's failure detail.
rc=0
out="$(echo '{"prompt":"do x"}' | \
  HARNESS_ROOT="${HARNESS_ROOT}" \
  HARNESS_SESSION="${_tmpdir}/outer" \
  HARNESS_SOURCES="${HARNESS_HOME}" \
  HARNESS_PROVIDER=mock \
  "${HARNESS_ROOT}/plugins/subagents/tools/agent" --exec 2>&1)" || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: agent tool should exit non-zero, got: ${out}"; exit 1; }
[[ "${out}" == *"subagent failed"* ]] || { echo "FAIL: expected marked failure, got: ${out}"; exit 1; }

echo "PASS"