#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_exec/10-exec"

# Create mock source dir with a tool
mock_src="${_tmpdir}/mock_src"
mkdir -p "${mock_src}/tools"
cat > "${mock_src}/tools/mock_tool" <<'TOOL'
#!/usr/bin/env bash
if [[ "${1:-}" == "--exec" ]]; then
  echo "mock result"
fi
TOOL
chmod +x "${mock_src}/tools/mock_tool"

# Create session.conf with cwd
echo "cwd=/tmp" > "${HARNESS_SESSION}/session.conf"

export HARNESS_SOURCES="${mock_src}"

out="$(echo '{"tool_calls":[{"id":"call_1","name":"mock_tool","input":{"arg":"val"}}]}' | "$hook")"

assert_json '.call_id'     "$out" "call_1"
assert_json '.name'        "$out" "mock_tool"
assert_json '.result'      "$out" "mock result"
assert_json '.error'       "$out" "false"
assert_json '.next_state'  "$out" "tool_done"
assert_json '.tool_calls | length' "$out" "0"
