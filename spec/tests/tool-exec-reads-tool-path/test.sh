#!/usr/bin/env bash
# Test: 10-exec reads HARNESS_TOOL_PATH from session.conf and bash tool can use it.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

# Create a mock tool accessible via .tool-bin
tool_bin="${HARNESS_SESSION}/.tool-bin"
mkdir -p "${tool_bin}"
cat > "${tool_bin}/read_file" <<'TOOL'
#!/usr/bin/env bash
case "${1:-}" in --describe) echo "Read a file";; --schema) echo '{}';; --exec) echo "read-file-output";; esac
TOOL
chmod +x "${tool_bin}/read_file"

# Create a bash tool that checks PATH
src="${_tmpdir}/src"
mkdir -p "${src}/tools"
cp "${HARNESS_ROOT}/plugins/core/tools/bash" "${src}/tools/bash"

# Write session.conf with HARNESS_TOOL_PATH
echo "HARNESS_TOOL_PATH=${tool_bin}" > "${HARNESS_SESSION}/session.conf"

export HARNESS_SOURCES="${src}"
# Ensure HARNESS_TOOL_PATH is NOT in env — 10-exec should read it from session.conf
unset HARNESS_TOOL_PATH

exec_hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_exec/10-exec"

# Execute a bash command that calls read_file by name
input='{"tool_calls":[{"id":"t1","name":"bash","input":{"command":"read_file --describe"}}]}'
result="$(echo "${input}" | "${exec_hook}" 2>/dev/null)"

tool_result="$(echo "${result}" | jq -r '.result')"
assert_eq "bash can find tool via HARNESS_TOOL_PATH" "${tool_result}" "Read a file"
