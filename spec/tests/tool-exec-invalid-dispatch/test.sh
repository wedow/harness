#!/usr/bin/env bash
# tool-exec-invalid-dispatch — a truncated/unparseable dispatch artifact must
# be dropped and the tool re-executed with the canonical input (the
# silent-corruption class produced empty/null results through half-written
# .tool_dispatch files).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_exec/10-exec"
mock_src="${_tmpdir}/mock_src"
mkdir -p "${mock_src}/tools"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --exec ]] && echo "canonical result"\n' > "${mock_src}/tools/mock_tool"
chmod +x "${mock_src}/tools/mock_tool"
echo "cwd=/tmp" > "${HARNESS_SESSION}/session.conf"
export HARNESS_SOURCES="${mock_src}"

# corrupt (truncated JSON) artifact for the call
mkdir -p "${HARNESS_SESSION}/.tool_dispatch"
printf '{"result": "canon' > "${HARNESS_SESSION}/.tool_dispatch/c1.json"

out="$(echo '{"tool_calls":[{"id":"c1","name":"mock_tool","input":{"a":1}}]}' | "$hook")"
assert_json '.result' "$out" "canonical result"
assert_json '.error' "$out" "false"
[[ -f "${HARNESS_SESSION}/.tool_dispatch/c1.json" ]] && { echo "FAIL: corrupt artifact not removed"; exit 1; }

# valid artifact still short-circuits (no re-execution)
printf '{"result":"cached","error":false}' > "${HARNESS_SESSION}/.tool_dispatch/c2.json"
out="$(echo '{"tool_calls":[{"id":"c2","name":"mock_tool","input":{}}]}' | "$hook")"
assert_json '.result' "$out" "cached"
