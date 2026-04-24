#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

tool="${HARNESS_ROOT}/plugins/core/tools/read_file"
export HARNESS_CWD="${_tmpdir}"

# Generate a 100-line file
file="${_tmpdir}/big.txt"
for i in $(seq 1 100); do echo "line ${i}"; done > "${file}"

# 1. Unbounded read of file exceeding limit should error
export HARNESS_READ_LIMIT=50
output=$(echo "{\"path\":\"${file}\"}" | "${tool}" --exec 2>&1) && {
  echo "FAIL: should-reject-large-file: expected non-zero exit"
  exit 1
}
assert_eq "error-mentions-lines" "$(echo "$output" | grep -c '100 lines')" "1"
assert_eq "error-mentions-limit" "$(echo "$output" | grep -c 'limit: 50')" "1"

# 2. Explicit limit bypasses the cap
output=$(echo "{\"path\":\"${file}\",\"limit\":10}" | "${tool}" --exec 2>&1)
assert_eq "limit-returns-10-lines" "$(echo "$output" | wc -l | tr -d ' ')" "10"
assert_eq "limit-starts-at-1" "$(echo "$output" | head -1 | sed 's/^[0-9]*#[A-Z][A-Z]://')" "line 1"

# 3. Offset bypasses the cap
output=$(echo "{\"path\":\"${file}\",\"offset\":90}" | "${tool}" --exec 2>&1)
assert_eq "offset-returns-tail" "$(echo "$output" | head -1 | sed 's/^[0-9]*#[A-Z][A-Z]://')" "line 90"

# 4. File under limit reads normally
export HARNESS_READ_LIMIT=200
output=$(echo "{\"path\":\"${file}\"}" | "${tool}" --exec 2>&1)
assert_eq "under-limit-full-read" "$(echo "$output" | wc -l | tr -d ' ')" "100"

# 5. Offset + limit reads correct window
unset HARNESS_READ_LIMIT
output=$(echo "{\"path\":\"${file}\",\"offset\":20,\"limit\":5}" | "${tool}" --exec 2>&1)
assert_eq "window-count" "$(echo "$output" | wc -l | tr -d ' ')" "5"
assert_eq "window-start" "$(echo "$output" | head -1 | sed 's/^[0-9]*#[A-Z][A-Z]://')" "line 20"
assert_eq "window-end" "$(echo "$output" | tail -1 | sed 's/^[0-9]*#[A-Z][A-Z]://')" "line 24"
