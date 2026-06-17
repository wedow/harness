#!/usr/bin/env bash
# Test: bash tool builds its tool PATH from HARNESS_SOURCES so discovered tools
# are callable by name inside a command (incl. recursive `agent` calls). 'bash'
# is excluded so nested shell calls hit the real bash; later sources win on
# name collisions, matching tool_exec resolution.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

# Two sources with tools; src2 is higher priority (last in HARNESS_SOURCES)
src1="${_tmpdir}/src1"
src2="${_tmpdir}/src2"
mkdir -p "${src1}/tools" "${src2}/tools"

printf '#!/usr/bin/env bash\necho "a from src1"' > "${src1}/tools/my_tool"
printf '#!/usr/bin/env bash\necho "a from src2"' > "${src2}/tools/my_tool"
printf '#!/usr/bin/env bash\necho "solo"'        > "${src1}/tools/solo_tool"
# A 'bash' tool that must NOT shadow the real shell.
printf '#!/usr/bin/env bash\necho "FAKE BASH"'   > "${src1}/tools/bash"
chmod +x "${src1}/tools/my_tool" "${src2}/tools/my_tool" \
         "${src1}/tools/solo_tool" "${src1}/tools/bash"

export HARNESS_SOURCES="${src1}:${src2}"
export HARNESS_CWD="${_tmpdir}"

bash_tool="${HARNESS_ROOT}/plugins/core/tools/bash"

# Tool callable by name; later source wins on collision.
result="$(echo '{"command":"my_tool"}' | "${bash_tool}" --exec)"
assert_eq "later source wins" "${result}" "a from src2"

# Tool present in only one source still resolves.
result="$(echo '{"command":"solo_tool"}' | "${bash_tool}" --exec)"
assert_eq "single-source tool" "${result}" "solo"

# 'bash' is NOT shadowed — a nested bash call uses the real shell.
result="$(echo '{"command":"bash -c \"echo real\""}' | "${bash_tool}" --exec)"
assert_eq "bash not shadowed" "${result}" "real"
