#!/usr/bin/env bash
# Test: the runtime version matches the latest released changelog version.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
export HARNESS_HOME="${_tmpdir}/home"

expected="$(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' "${HARNESS_ROOT}/CHANGELOG.md" | head -1)"
actual="$("${HARNESS_ROOT}/bin/harness" version)"

if [[ "${actual}" != "harness ${expected}" ]]; then
  echo "FAIL: expected 'harness ${expected}', got '${actual}'"
  exit 1
fi

echo "PASS"
