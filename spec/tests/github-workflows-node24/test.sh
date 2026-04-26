#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

matches="$(find "${HARNESS_ROOT}/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 | xargs -0 rg -n "actions/checkout@v4" || true)"

if [[ -n "${matches}" ]]; then
  echo "FAIL: workflows still pin actions/checkout@v4"
  echo "${matches}"
  exit 1
fi

echo "PASS"