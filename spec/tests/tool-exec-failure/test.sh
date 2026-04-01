#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_exec/10-exec"

# Create mock source dir with a failing tool
mock_src="${_tmpdir}/mock_src"
mkdir -p "${mock_src}/tools"
cat > "${mock_src}/tools/fail_tool" <<'TOOL'
#!/usr/bin/env bash
if [[ "${1:-}" == "--exec" ]]; then
  echo "command failed"
  exit 1
fi
TOOL
chmod +x "${mock_src}/tools/fail_tool"

echo "cwd=/tmp" > "${HARNESS_SESSION}/session.conf"

export HARNESS_SOURCES="${mock_src}"

out="$(echo '{"tool_calls":[{"id":"call_3","name":"fail_tool","input":{}}]}' | "$hook")"

assert_json '.error' "$out" "true"

result="$(echo "$out" | jq -r '.result')"
[[ "$result" == *"command failed"* ]] || { echo "FAIL: result should contain 'command failed', got: $result"; exit 1; }
