#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

read_tool="${HARNESS_ROOT}/plugins/core/tools/read_file"
edit_tool="${HARNESS_ROOT}/plugins/core/tools/edit_file"
export HARNESS_CWD="${_tmpdir}"

file="${_tmpdir}/val.txt"
printf 'alpha\nbeta\ngamma\n' > "${file}"

# Get the correct anchor for line 2
read_output=$(echo "{\"path\":\"${file}\"}" | "${read_tool}" --exec)
correct_hash=$(echo "${read_output}" | grep "^2#" | sed 's/^[0-9]*#\([A-Z][A-Z]\):.*/\1/')

# Pick a stale hash that differs from the correct one
if [[ "${correct_hash}" == "ZZ" ]]; then stale_hash="PP"; else stale_hash="ZZ"; fi

# Helper: run edit_file expecting failure, capture output
expect_fail() {
  local label="$1" input="$2"
  local out rc=0
  out=$(echo "${input}" | "${edit_tool}" --exec 2>&1) || rc=$?
  if (( rc == 0 )); then
    echo "FAIL: ${label}: expected non-zero exit"
    exit 1
  fi
  echo "${out}"
}

# 1. Stale hash is rejected with exit code 1
output=$(expect_fail "stale-hash" "$(jq -n --arg path "${file}" \
  '{path:$path, edits:[{type:"replace_range", pos:"2#'"${stale_hash}"'", end:"2#'"${stale_hash}"'", content:["changed"]}]}')")

# 2. Error message contains "MISMATCH"
echo "${output}" | grep -q "MISMATCH" || {
  echo "FAIL: error-mentions-mismatch: output was: ${output}"
  exit 1
}

# 3. Error message includes >>> marker showing correct anchor
echo "${output}" | grep -q ">>>" || {
  echo "FAIL: error-has-marker: output was: ${output}"
  exit 1
}

# 4. Invalid anchor format: wrong alphabet letters
output=$(expect_fail "wrong-alphabet" "$(jq -n --arg path "${file}" \
  '{path:$path, edits:[{type:"replace_range", pos:"2#ab", end:"2#ab", content:["x"]}]}')")
echo "${output}" | grep -qi "invalid" || {
  echo "FAIL: wrong-alphabet-error-msg: output was: ${output}"
  exit 1
}

# 5. Invalid anchor format: missing # separator
output=$(expect_fail "missing-hash" "$(jq -n --arg path "${file}" \
  '{path:$path, edits:[{type:"replace_range", pos:"2ZZ", end:"2ZZ", content:["x"]}]}')")
echo "${output}" | grep -qi "invalid" || {
  echo "FAIL: missing-hash-error-msg: output was: ${output}"
  exit 1
}

# 6. Invalid anchor format: single letter hash
expect_fail "single-letter" "$(jq -n --arg path "${file}" \
  '{path:$path, edits:[{type:"replace_range", pos:"2#Z", end:"2#Z", content:["x"]}]}')" >/dev/null

# 7. Out-of-range line number is rejected
expect_fail "out-of-range" "$(jq -n --arg path "${file}" \
  '{path:$path, edits:[{type:"replace_range", pos:"99#ZZ", end:"99#ZZ", content:["x"]}]}')" >/dev/null
