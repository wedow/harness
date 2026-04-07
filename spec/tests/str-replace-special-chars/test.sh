#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

tool="${HARNESS_ROOT}/plugins/core/tools/str_replace"
export HARNESS_CWD="${_tmpdir}"

# Helper: write file, run str_replace, assert result
run_replace() {
  local label="$1" initial="$2" old="$3" new="$4" expected="$5"
  local file="${_tmpdir}/${label}.txt"
  printf '%s' "$initial" > "$file"
  jq -n --arg path "$file" --arg old "$old" --arg new "$new" \
    '{path:$path, old_str:$old, new_str:$new}' | "$tool" --exec >/dev/null
  local actual
  actual="$(cat "$file")"
  assert_eq "$label" "$actual" "$expected"
}

# 1. Dollar signs in new_str
run_replace "dollar-sign" "PLACEHOLDER" "PLACEHOLDER" 'cost is $100' 'cost is $100'

# 2. Backticks in new_str
run_replace "backticks" "PLACEHOLDER" "PLACEHOLDER" 'run `cmd` here' 'run `cmd` here'

# 3. Backslashes in new_str
run_replace "backslashes" "PLACEHOLDER" "PLACEHOLDER" 'path\to\file' 'path\to\file'

# 4. Unbalanced braces in old_str
run_replace "unbalanced-brace" 'if (x) { return; }' 'if (x) {' 'if (y) {' 'if (y) { return; }'

# 5. At signs in new_str
run_replace "at-sign" "PLACEHOLDER" "PLACEHOLDER" 'user@host' 'user@host'

# 6. Perl regex metacharacters in old_str
run_replace "regex-meta" 'price: $5.00 total' 'price: $5.00' 'price: 5 USD' 'price: 5 USD total'
