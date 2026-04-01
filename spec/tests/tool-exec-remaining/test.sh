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
  echo "ok"
fi
TOOL
chmod +x "${mock_src}/tools/mock_tool"

echo "cwd=/tmp" > "${HARNESS_SESSION}/session.conf"

export HARNESS_SOURCES="${mock_src}"

out="$(echo '{"tool_calls":[{"id":"c1","name":"mock_tool","input":{}},{"id":"c2","name":"mock_tool","input":{}}]}' | "$hook")"

assert_json '.tool_calls | length' "$out" "1"
assert_json '.tool_calls[0].id'    "$out" "c2"
