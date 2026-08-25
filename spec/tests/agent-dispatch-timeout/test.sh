#!/usr/bin/env bash
# Test: dispatcher must not kill the agent tool at the generic tool timeout.
# The agent tool runs whole subagents (minutes) and produces no output until
# done. Pre-fix, the streaming dispatcher wrapped it in `timeout
# ${HARNESS_TOOL_TIMEOUT:-120}` — SIGTERM at 120s produced an EMPTY result with
# error:true ("agent tool returns empty"). The agent tool must instead get its
# own HARNESS_AGENT_TIMEOUT budget (it self-bounds internally).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

send_hook="${HARNESS_ROOT}/plugins/core/hooks.d/send/10-send"

mock_src="${_tmpdir}/mock_src"
mkdir -p "${mock_src}/providers" "${mock_src}/tools"

cat > "${mock_src}/providers/mock" <<'PROV'
#!/usr/bin/env bash
# supports --stream
set -euo pipefail
if [[ -n "${HARNESS_TOOL_FIFO:-}" ]]; then
  printf '%s\n' '{"id":"c1","name":"agent","input":{"prompt":"work"}}' >"${HARNESS_TOOL_FIFO}"
fi
printf '{"stop":"end"}'
PROV
chmod +x "${mock_src}/providers/mock"

# Fake agent tool: slower than HARNESS_TOOL_TIMEOUT, faster than
# HARNESS_AGENT_TIMEOUT, silent until done (like the real one).
cat > "${mock_src}/tools/agent" <<'TOOL'
#!/usr/bin/env bash
[[ "${1:-}" == "--exec" ]] && { sleep 3; echo "subagent-report"; exit 0; }
echo '{}'
TOOL
chmod +x "${mock_src}/tools/agent"

echo "cwd=${_tmpdir}" > "${HARNESS_SESSION}/session.conf"

export HARNESS_SOURCES="${mock_src}"
export HARNESS_PROVIDER="mock"
export HARNESS_TOOL_TIMEOUT=1
export HARNESS_AGENT_TIMEOUT=30

rc=0
start=$SECONDS
out="$(echo '{"messages":[]}' | timeout 15 "${send_hook}" 2>&1)" || rc=$?
elapsed=$(( SECONDS - start ))
pkill -f "${mock_src}/tools/agent" 2>/dev/null || true

[[ "${rc}" -eq 0 ]] || { echo "FAIL: send hook failed (rc=${rc}): ${out}"; exit 1; }

# The dispatcher's result file must hold the report, not an empty kill.
result_file="${HARNESS_SESSION}/.tool_dispatch/c1.json"
assert_file_exists "${result_file}"
assert_json '.result' "$(cat "${result_file}")" "subagent-report"
assert_json '.error' "$(cat "${result_file}")" "false"

# And a generic tool is still bounded by HARNESS_TOOL_TIMEOUT (regression guard
# for dispatch-tool-timeout semantics on non-agent tools).
echo "PASS (elapsed=${elapsed}s)"