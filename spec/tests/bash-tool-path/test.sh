#!/usr/bin/env bash
# Test: bash tool prepends HARNESS_TOOL_PATH to PATH so tools are callable by name.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

# Create a mock tool in a tool-bin directory
tool_bin="${_tmpdir}/tool-bin"
mkdir -p "${tool_bin}"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --describe) echo "mock tool";; *) echo "mock-output";; esac' \
  > "${tool_bin}/my_tool"
chmod +x "${tool_bin}/my_tool"

export HARNESS_TOOL_PATH="${tool_bin}"
export HARNESS_CWD="${_tmpdir}"

bash_tool="${HARNESS_ROOT}/plugins/core/tools/bash"

# The tool should be callable by name from within a bash command
result="$(echo '{"command":"my_tool --describe"}' | "${bash_tool}" --exec)"
assert_eq "tool on PATH" "${result}" "mock tool"
