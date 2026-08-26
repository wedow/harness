#!/usr/bin/env bash
# Test: streaming dispatcher honors a tool's per-call timeout request. The
# wrapper (HARNESS_TOOL_TIMEOUT, default 120) must never kill a call the tool
# itself would allow to run longer — the tool emits its result only at
# completion, so an early wrapper kill surfaces as an EMPTY error result
# (the "long bench run returns nothing" failure mode).
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
  printf '%s\n' '{"id":"c1","name":"slow_tool","input":{"timeout":5}}' >"${HARNESS_TOOL_FIFO}"
fi
printf '{"stop":"end"}'
PROV
chmod +x "${mock_src}/providers/mock"

# Sleeps past the env tool timeout; only its per-call request can save it.
cat > "${mock_src}/tools/slow_tool" <<'TOOL'
#!/usr/bin/env bash
[[ "${1:-}" == "--exec" ]] && { sleep 3; echo "slow-done"; exit 0; }
echo '{}'
TOOL
chmod +x "${mock_src}/tools/slow_tool"

echo "cwd=${_tmpdir}" > "${HARNESS_SESSION}/session.conf"

export HARNESS_SOURCES="${mock_src}"
export HARNESS_PROVIDER="mock"
export HARNESS_TOOL_TIMEOUT=1

rc=0
out="$(echo '{"messages":[]}' | timeout 15 "${send_hook}" 2>&1)" || rc=$?
pkill -f "${mock_src}/tools/slow_tool" 2>/dev/null || true

[[ "${rc}" -eq 0 ]] || { echo "FAIL: send hook failed (rc=${rc}): ${out}"; exit 1; }

result_file="${HARNESS_SESSION}/.tool_dispatch/c1.json"
assert_file_exists "${result_file}"
assert_json '.result' "$(cat "${result_file}")" "slow-done"
assert_json '.error' "$(cat "${result_file}")" "false"

echo "PASS"