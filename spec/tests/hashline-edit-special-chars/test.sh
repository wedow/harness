#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

read_tool="${HARNESS_ROOT}/plugins/core/tools/read_file"
edit_tool="${HARNESS_ROOT}/plugins/core/tools/edit_file"
export HARNESS_CWD="${_tmpdir}"

# Helper: create file, replace line 2, verify line 2 matches expected
test_special_content() {
  local label="$1" content="$2"
  local file="${_tmpdir}/${label}.txt"
  printf 'before\nPLACEHOLDER\nafter\n' > "${file}"
  local anchor
  anchor=$(echo "{\"path\":\"${file}\"}" | "${read_tool}" --exec \
    | grep "^2#" | sed 's/^\([0-9]*#[A-Z][A-Z]\):.*/\1/')
  jq -n --arg path "${file}" --arg pos "${anchor}" --arg end "${anchor}" --arg c "${content}" \
    '{path:$path, edits:[{type:"replace_range", pos:$pos, end:$end, content:[$c]}]}' \
    | "${edit_tool}" --exec >/dev/null
  local actual
  actual="$(sed -n '2p' "${file}")"
  assert_eq "${label}" "${actual}" "${content}"
}

# 1. Dollar signs
test_special_content "dollar-signs" 'price is $100 and $VAR'

# 2. Backticks
test_special_content "backticks" 'run `echo hello` now'

# 3. Backslashes
test_special_content "backslashes" 'path\to\file\n'

# 4. Single quotes
test_special_content "single-quotes" "it's a 'test'"

# 5. Double quotes
test_special_content "double-quotes" 'she said "hello"'

# 6. Pipes and redirects
test_special_content "pipes-redirects" 'cat foo | grep bar > out 2>&1'
