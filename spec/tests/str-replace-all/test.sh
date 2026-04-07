#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

tool="${HARNESS_ROOT}/plugins/core/tools/str_replace"
export HARNESS_CWD="${_tmpdir}"

file="${_tmpdir}/test.txt"

# 1. Multiple occurrences without replace_all should error
printf 'foo bar foo baz foo' > "${file}"
output=$(echo "{\"path\":\"${file}\",\"old_str\":\"foo\",\"new_str\":\"qux\"}" | "${tool}" --exec 2>&1) && {
  echo "FAIL: multi-no-flag: expected non-zero exit"
  exit 1
}
assert_eq "error-mentions-count" "$(echo "$output" | grep -c '3 times')" "1"
assert_eq "error-mentions-replace-all" "$(echo "$output" | grep -c 'replace_all')" "1"

# 2. replace_all replaces all occurrences
printf 'foo bar foo baz foo' > "${file}"
output=$(jq -n --arg p "${file}" '{path:$p, old_str:"foo", new_str:"qux", replace_all:true}' | "${tool}" --exec 2>&1)
assert_eq "replace-all-output" "$output" "replaced 3 occurrences in ${file}"
assert_eq "replace-all-content" "$(cat "${file}")" "qux bar qux baz qux"

# 3. replace_all with single occurrence works fine
printf 'one unique thing' > "${file}"
jq -n --arg p "${file}" '{path:$p, old_str:"unique", new_str:"special", replace_all:true}' | "${tool}" --exec >/dev/null
assert_eq "replace-all-single" "$(cat "${file}")" "one special thing"
