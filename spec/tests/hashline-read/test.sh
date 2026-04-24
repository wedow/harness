#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

tool="${HARNESS_ROOT}/plugins/core/tools/read_file"
export HARNESS_CWD="${_tmpdir}"

file="${_tmpdir}/sample.txt"
printf 'alpha\nbeta\ngamma\ndelta\nepsilon\n' > "${file}"

# 1. Full read produces LINENUM#HASH:content format
output=$(echo "{\"path\":\"${file}\"}" | "${tool}" --exec)
assert_eq "line-count" "$(echo "${output}" | wc -l | tr -d ' ')" "5"
assert_eq "line-1-content" "$(echo "${output}" | head -1 | sed 's/^[0-9]*#[A-Z][A-Z]://')" "alpha"
assert_eq "line-5-content" "$(echo "${output}" | tail -1 | sed 's/^[0-9]*#[A-Z][A-Z]://')" "epsilon"

# 2. Hash is exactly 2 uppercase letters from the NIBBLE alphabet
while IFS= read -r line; do
  hash=$(echo "${line}" | sed 's/^[0-9]*#\([A-Z][A-Z]\):.*/\1/')
  if [[ ! "${hash}" =~ ^[ZPMQVRWSNKTXJBYH]{2}$ ]]; then
    echo "FAIL: bad-hash-format: '${hash}' on line: ${line}"
    exit 1
  fi
done <<< "${output}"

# 3. Line numbers are correct and sequential
for i in 1 2 3 4 5; do
  linenum=$(echo "${output}" | sed -n "${i}p" | sed 's/^\([0-9]*\)#.*/\1/')
  assert_eq "linenum-${i}" "${linenum}" "${i}"
done

# 4. offset parameter starts at the right line
output=$(echo "{\"path\":\"${file}\",\"offset\":3}" | "${tool}" --exec)
assert_eq "offset-count" "$(echo "${output}" | wc -l | tr -d ' ')" "3"
assert_eq "offset-first-linenum" "$(echo "${output}" | head -1 | sed 's/^\([0-9]*\)#.*/\1/')" "3"
assert_eq "offset-first-content" "$(echo "${output}" | head -1 | sed 's/^[0-9]*#[A-Z][A-Z]://')" "gamma"

# 5. limit parameter restricts to N lines
output=$(echo "{\"path\":\"${file}\",\"limit\":2}" | "${tool}" --exec)
assert_eq "limit-count" "$(echo "${output}" | wc -l | tr -d ' ')" "2"
assert_eq "limit-last-content" "$(echo "${output}" | tail -1 | sed 's/^[0-9]*#[A-Z][A-Z]://')" "beta"

# 6. offset + limit together
output=$(echo "{\"path\":\"${file}\",\"offset\":2,\"limit\":2}" | "${tool}" --exec)
assert_eq "offset-limit-count" "$(echo "${output}" | wc -l | tr -d ' ')" "2"
assert_eq "offset-limit-first" "$(echo "${output}" | head -1 | sed 's/^[0-9]*#[A-Z][A-Z]://')" "beta"
assert_eq "offset-limit-last" "$(echo "${output}" | tail -1 | sed 's/^[0-9]*#[A-Z][A-Z]://')" "gamma"

# 7. Identical content lines get the SAME hash
dup_file="${_tmpdir}/dup.txt"
printf 'hello\nworld\nhello\n' > "${dup_file}"
output=$(echo "{\"path\":\"${dup_file}\"}" | "${tool}" --exec)
hash_1=$(echo "${output}" | grep "^1#" | sed 's/^[0-9]*#\([A-Z][A-Z]\):.*/\1/')
hash_3=$(echo "${output}" | grep "^3#" | sed 's/^[0-9]*#\([A-Z][A-Z]\):.*/\1/')
assert_eq "identical-content-same-hash" "${hash_1}" "${hash_3}"

# 8. Structural-only lines get DIFFERENT hashes at different positions
struct_file="${_tmpdir}/struct.txt"
printf '}\n}\n' > "${struct_file}"
output=$(echo "{\"path\":\"${struct_file}\"}" | "${tool}" --exec)
hash_s1=$(echo "${output}" | grep "^1#" | sed 's/^[0-9]*#\([A-Z][A-Z]\):.*/\1/')
hash_s2=$(echo "${output}" | grep "^2#" | sed 's/^[0-9]*#\([A-Z][A-Z]\):.*/\1/')
if [[ "${hash_s1}" == "${hash_s2}" ]]; then
  echo "FAIL: structural-lines-different-hash: both got '${hash_s1}'"
  exit 1
fi
