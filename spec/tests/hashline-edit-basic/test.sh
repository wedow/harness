#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

read_tool="${HARNESS_ROOT}/plugins/core/tools/read_file"
edit_tool="${HARNESS_ROOT}/plugins/core/tools/edit_file"
export HARNESS_CWD="${_tmpdir}"

# Helper: read file and extract anchor for a given line number
get_anchor() {
  local file="$1" linenum="$2"
  echo "{\"path\":\"${file}\"}" | "${read_tool}" --exec \
    | grep "^${linenum}#" | sed 's/^\([0-9]*#[A-Z][A-Z]\):.*/\1/'
}

# 1. replace_range single line
file="${_tmpdir}/replace1.txt"
printf 'aaa\nbbb\nccc\n' > "${file}"
anchor=$(get_anchor "${file}" 2)
jq -n --arg path "${file}" --arg pos "${anchor}" --arg end "${anchor}" \
  '{path:$path, edits:[{type:"replace_range", pos:$pos, end:$end, content:["XXX"]}]}' \
  | "${edit_tool}" --exec >/dev/null
assert_eq "replace-single" "$(sed -n '2p' "${file}")" "XXX"
assert_eq "replace-single-before" "$(sed -n '1p' "${file}")" "aaa"
assert_eq "replace-single-after" "$(sed -n '3p' "${file}")" "ccc"

# 2. replace_range multi-line
file="${_tmpdir}/replace2.txt"
printf 'line1\nline2\nline3\nline4\nline5\n' > "${file}"
pos=$(get_anchor "${file}" 2)
end=$(get_anchor "${file}" 4)
jq -n --arg path "${file}" --arg pos "${pos}" --arg end "${end}" \
  '{path:$path, edits:[{type:"replace_range", pos:$pos, end:$end, content:["NEW2","NEW3"]}]}' \
  | "${edit_tool}" --exec >/dev/null
assert_eq "replace-multi-line1" "$(sed -n '1p' "${file}")" "line1"
assert_eq "replace-multi-new1" "$(sed -n '2p' "${file}")" "NEW2"
assert_eq "replace-multi-new2" "$(sed -n '3p' "${file}")" "NEW3"
assert_eq "replace-multi-line5" "$(sed -n '4p' "${file}")" "line5"
assert_eq "replace-multi-linecount" "$(wc -l < "${file}" | tr -d ' ')" "4"

# 3. Delete via replace_range with null content
file="${_tmpdir}/delete.txt"
printf 'keep1\nremove\nkeep2\n' > "${file}"
anchor=$(get_anchor "${file}" 2)
jq -n --arg path "${file}" --arg pos "${anchor}" --arg end "${anchor}" \
  '{path:$path, edits:[{type:"replace_range", pos:$pos, end:$end, content:null}]}' \
  | "${edit_tool}" --exec >/dev/null
assert_eq "delete-linecount" "$(wc -l < "${file}" | tr -d ' ')" "2"
assert_eq "delete-line1" "$(sed -n '1p' "${file}")" "keep1"
assert_eq "delete-line2" "$(sed -n '2p' "${file}")" "keep2"

# 4. append_at: insert lines after a specific line
file="${_tmpdir}/append_at.txt"
printf 'first\nsecond\nthird\n' > "${file}"
anchor=$(get_anchor "${file}" 2)
jq -n --arg path "${file}" --arg pos "${anchor}" \
  '{path:$path, edits:[{type:"append_at", pos:$pos, content:["inserted"]}]}' \
  | "${edit_tool}" --exec >/dev/null
assert_eq "append-at-line2" "$(sed -n '2p' "${file}")" "second"
assert_eq "append-at-inserted" "$(sed -n '3p' "${file}")" "inserted"
assert_eq "append-at-line3" "$(sed -n '4p' "${file}")" "third"
assert_eq "append-at-linecount" "$(wc -l < "${file}" | tr -d ' ')" "4"

# 5. prepend_at: insert lines before a specific line
file="${_tmpdir}/prepend_at.txt"
printf 'first\nsecond\nthird\n' > "${file}"
anchor=$(get_anchor "${file}" 2)
jq -n --arg path "${file}" --arg pos "${anchor}" \
  '{path:$path, edits:[{type:"prepend_at", pos:$pos, content:["inserted"]}]}' \
  | "${edit_tool}" --exec >/dev/null
assert_eq "prepend-at-line1" "$(sed -n '1p' "${file}")" "first"
assert_eq "prepend-at-inserted" "$(sed -n '2p' "${file}")" "inserted"
assert_eq "prepend-at-line2" "$(sed -n '3p' "${file}")" "second"
assert_eq "prepend-at-linecount" "$(wc -l < "${file}" | tr -d ' ')" "4"

# 6. append_file: add lines at end
file="${_tmpdir}/append_file.txt"
printf 'existing\n' > "${file}"
jq -n --arg path "${file}" \
  '{path:$path, edits:[{type:"append_file", content:["tail1","tail2"]}]}' \
  | "${edit_tool}" --exec >/dev/null
assert_eq "append-file-linecount" "$(wc -l < "${file}" | tr -d ' ')" "3"
assert_eq "append-file-tail1" "$(sed -n '2p' "${file}")" "tail1"
assert_eq "append-file-tail2" "$(sed -n '3p' "${file}")" "tail2"

# 7. prepend_file: add lines at start
file="${_tmpdir}/prepend_file.txt"
printf 'existing\n' > "${file}"
jq -n --arg path "${file}" \
  '{path:$path, edits:[{type:"prepend_file", content:["head1","head2"]}]}' \
  | "${edit_tool}" --exec >/dev/null
assert_eq "prepend-file-linecount" "$(wc -l < "${file}" | tr -d ' ')" "3"
assert_eq "prepend-file-head1" "$(sed -n '1p' "${file}")" "head1"
assert_eq "prepend-file-head2" "$(sed -n '2p' "${file}")" "head2"
assert_eq "prepend-file-existing" "$(sed -n '3p' "${file}")" "existing"
