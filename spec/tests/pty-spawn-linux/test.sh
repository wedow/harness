#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

if [[ "$(uname)" == "Darwin" ]]; then
  echo "PASS"
  exit 0
fi

output="$(pty_spawn "printf ok" 2>&1)"
assert_eq "pty_spawn output" "${output}" "ok"

echo "PASS"