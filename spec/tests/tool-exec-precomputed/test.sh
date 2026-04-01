#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_exec/10-exec"

# Create precomputed result
mkdir -p "${HARNESS_SESSION}/.tool_dispatch"
echo '{"result":"precomputed output","error":false}' > "${HARNESS_SESSION}/.tool_dispatch/call_pre.json"

# Need a source dir (even though we won't use a tool binary)
mock_src="${_tmpdir}/mock_src"
mkdir -p "${mock_src}/tools"
echo "cwd=/tmp" > "${HARNESS_SESSION}/session.conf"

export HARNESS_SOURCES="${mock_src}"

out="$(echo '{"tool_calls":[{"id":"call_pre","name":"bash","input":{}}]}' | "$hook")"

assert_json '.result'     "$out" "precomputed output"
assert_json '.error'      "$out" "false"
assert_json '.next_state' "$out" "tool_done"
