#!/usr/bin/env bash
# Test: 10-tool-path start hook creates .tool-bin/ with symlinks and persists HARNESS_TOOL_PATH.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

# Create a mock source with a tool
src1="${_tmpdir}/src1"
src2="${_tmpdir}/src2"
mkdir -p "${src1}/tools" "${src2}/tools"

printf '#!/usr/bin/env bash\necho "tool-a from src1"' > "${src1}/tools/tool_a"
printf '#!/usr/bin/env bash\necho "tool-b from src1"' > "${src1}/tools/tool_b"
printf '#!/usr/bin/env bash\necho "tool-a from src2"' > "${src2}/tools/tool_a"
chmod +x "${src1}/tools/tool_a" "${src1}/tools/tool_b" "${src2}/tools/tool_a"

export HARNESS_SOURCES="${src1}:${src2}"
touch "${HARNESS_SESSION}/session.conf"

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/start/10-tool-path"
out="$(echo '{}' | "${hook}")"

# .tool-bin/ should exist
[[ -d "${HARNESS_SESSION}/.tool-bin" ]] || { echo "FAIL: .tool-bin/ not created"; exit 1; }

# tool_a should resolve to src2 (higher priority)
target_a="$(readlink "${HARNESS_SESSION}/.tool-bin/tool_a")"
expected_a="$(realpath "${src2}/tools/tool_a")"
assert_eq "tool_a symlink" "${target_a}" "${expected_a}"

# tool_b should resolve to src1 (only source)
target_b="$(readlink "${HARNESS_SESSION}/.tool-bin/tool_b")"
expected_b="$(realpath "${src1}/tools/tool_b")"
assert_eq "tool_b symlink" "${target_b}" "${expected_b}"

# HARNESS_TOOL_PATH should be persisted in session.conf
grep -q "^HARNESS_TOOL_PATH=${HARNESS_SESSION}/.tool-bin$" "${HARNESS_SESSION}/session.conf" \
  || { echo "FAIL: HARNESS_TOOL_PATH not in session.conf"; exit 1; }

# Hook should pass through input unchanged
assert_json '.' "${out}" '{}'
