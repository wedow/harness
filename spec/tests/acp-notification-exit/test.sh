#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSIONS="${_tmpdir}/sessions"
export HARNESS_HOME="${_tmpdir}/home"
export HARNESS_MODEL=""
mkdir -p "${HARNESS_SESSIONS}" "${HARNESS_HOME}"

acp="${HARNESS_ROOT}/plugins/core/commands/acp"

# A notification has no "id" field. When it's the last message before EOF,
# the adapter should still exit 0.
echo '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  | "$acp" 2>/dev/null
assert_eq "exit code" "$?" "0"

echo "PASS"
