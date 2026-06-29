#!/usr/bin/env bash
# Reproduces the ARG_MAX crash: a tool whose combined stdout+stderr exceeds the
# kernel's ARG_MAX must still produce valid tool_exec output. Pre-fix, the hook
# passed ${result} as a jq CLI argument, exceeded ARG_MAX, and jq died with
# "Argument list too long".
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_exec/10-exec"

mock_src="${_tmpdir}/mock_src"
mkdir -p "${mock_src}/tools"
cat > "${mock_src}/tools/big_tool" <<'TOOL'
#!/usr/bin/env bash
if [[ "${1:-}" == "--exec" ]]; then
  size=$(( $(getconf ARG_MAX) + 1024 ))
  head -c "$size" /dev/zero | tr '\0' 'x'
fi
TOOL
chmod +x "${mock_src}/tools/big_tool"

echo "cwd=/tmp" > "${HARNESS_SESSION}/session.conf"
export HARNESS_SOURCES="${mock_src}"

out="$(echo '{"tool_calls":[{"id":"call_big","name":"big_tool","input":{}}]}' | "$hook")"

assert_json '.call_id'    "$out" "call_big"
assert_json '.name'       "$out" "big_tool"
assert_json '.error'      "$out" "false"
assert_json '.next_state' "$out" "tool_done"

expected=$(( $(getconf ARG_MAX) + 1024 ))
actual="$(printf '%s' "$out" | jq '.result | length')"
[[ "${actual}" == "${expected}" ]] || {
  printf 'FAIL: result length expected %s got %s\n' "${expected}" "${actual}"
  exit 1
}
