#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/assemble/20-tools"

# Create a mock source with a tool that responds to --schema
src="${_tmpdir}/source"
make_sources "$src"
mkdir -p "${src}/tools"

cat > "${src}/tools/mock_tool" <<'TOOL'
#!/usr/bin/env bash
case "$1" in
  --schema) echo '{"name":"mock_tool","description":"a mock tool","input_schema":{"type":"object"}}' ;;
esac
TOOL
chmod +x "${src}/tools/mock_tool"

# Test: tool schema is discovered and added to payload
out="$(echo '{}' | "$hook")"
assert_json '.tools | length' "$out" "1"
assert_json '.tools[0].name' "$out" "mock_tool"
